import Testing
import Foundation
@testable import DNSChainCore

struct MockUpstream: DNSUpstream {
    let id: String
    let name: String
    let type: UpstreamType
    let response: Data?
    let error: Error?

    func query(_ request: Data) async throws -> UpstreamResponse {
        if let error { throw error }
        let data = try #require(response)
        return UpstreamResponse(
            message: try DNSMessage.parse(data),
            attempt: AttemptLog(upstreamID: id, upstreamName: name, status: .success, latencyMs: 1)
        )
    }
}

struct DynamicMockUpstream: DNSUpstream {
    let id: String
    let name: String
    let type: UpstreamType
    let makeResponse: @Sendable (Data) throws -> Data

    func query(_ request: Data) async throws -> UpstreamResponse {
        let data = try makeResponse(request)
        return UpstreamResponse(
            message: try DNSMessage.parse(data),
            attempt: AttemptLog(upstreamID: id, upstreamName: name, status: .success, latencyMs: 1)
        )
    }
}

@Test
func servfailResponseUsesOriginalQuestion() async throws {
    let resolver = ChainResolver(config: DNSChainConfig(dnsChain: []))
    let query = Data.makeQuery(id: 0x1111, name: "example.com", type: 1)
    let response = try await resolver.resolve(query)
    let parsed = try DNSMessage.parse(response)
    #expect(parsed.id == 0x1111)
    #expect(parsed.rcode == .servFail)
    #expect(parsed.question.normalizedName == "example.com")
}

@Test
func exhaustedEmptyAnswerReturnsNoDataResponse() async throws {
    let query = Data.makeQuery(id: 0x2222, name: "macwk.com", type: 28)
    let noData = DNSMessage.makeErrorResponse(for: query, rcode: .noError)
    let upstream = MockUpstream(
        id: "mock",
        name: "Mock DNS",
        type: .doh,
        response: noData,
        error: nil
    )
    let resolver = ChainResolver(config: DNSChainConfig(dnsChain: []), upstreams: [upstream])

    let response = try await resolver.resolve(query)
    let parsed = try DNSMessage.parse(response)
    let logs = await resolver.recentLogs(limit: 1)

    #expect(parsed.id == 0x2222)
    #expect(parsed.rcode == .noError)
    #expect(parsed.answers.isEmpty)
    #expect(logs.first?.qtype == 28)
    #expect(logs.first?.attempts.first?.status == .emptyAnswer)
}

@Test
func configuredCNameSuffixTriggersBlockedFallback() async throws {
    let answers = [
        DNSAnswer(
            name: "example.com",
            type: .cname,
            rawType: 5,
            ttl: 60,
            value: "blocked.example.test"
        )
    ]
    let matcher = BlockedAnswerMatcher(config: BlockedAnswersConfig(cnameSuffixes: [".example.test"]))

    #expect(matcher.blockedCNAME(in: answers) == "blocked.example.test")
}

@Test
func blockedSystemAnswerRecordsBypassAndSkipsSystemForSubdomains() async throws {
    let bypassURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("dns-chain-tests-\(UUID().uuidString)")
        .appendingPathComponent("system-bypass.txt")
    let bypass = SystemBypassStore(fileURL: bypassURL)
    let system = DynamicMockUpstream(id: "system", name: "系统 DNS", type: .system) { request in
        try Data.makeCNameResponse(for: request, cname: "blocked.example.test")
    }
    let doh = DynamicMockUpstream(id: "doh", name: "DoH", type: .doh) { request in
        try Data.makeAResponse(for: request, ip: "203.0.113.10")
    }
    let resolver = ChainResolver(
        config: DNSChainConfig(dnsChain: [], blockedAnswers: BlockedAnswersConfig(cnameSuffixes: [".example.test"])),
        systemBypass: bypass,
        upstreams: [system, doh]
    )

    _ = try await resolver.resolve(Data.makeQuery(id: 0x3333, name: "blocked.example.com", type: 1))
    let learnedDomains = await bypass.allDomains()
    #expect(learnedDomains == ["blocked.example.com"])

    _ = try await resolver.resolve(Data.makeQuery(id: 0x4444, name: "child.blocked.example.com", type: 1))
    let logs = await resolver.recentLogs(limit: 1)
    #expect(logs.first?.attempts.map(\.status) == [.skippedSystem, .success])
    #expect(logs.first?.finalUpstream == "doh")
}

@Test
func invalidResponseFallbackCanBeDisabled() async throws {
    let query = Data.makeQuery(id: 0x5555, name: "unsupported.example.com", type: 1)
    let invalid = DNSMessage.makeErrorResponse(for: query, rcode: .notImp)
    let invalidUpstream = MockUpstream(
        id: "invalid",
        name: "Invalid DNS",
        type: .doh,
        response: invalid,
        error: nil
    )
    let fallbackUpstream = DynamicMockUpstream(id: "fallback", name: "Fallback DNS", type: .doh) { request in
        try Data.makeAResponse(for: request, ip: "203.0.113.20")
    }
    let config = DNSChainConfig(
        dnsChain: [],
        fallbackWhen: FallbackConfig(invalidResponse: false)
    )
    let resolver = ChainResolver(config: config, upstreams: [invalidUpstream, fallbackUpstream])

    let response = try await resolver.resolve(query)
    let parsed = try DNSMessage.parse(response)
    let logs = await resolver.recentLogs(limit: 1)

    #expect(parsed.rcode == .notImp)
    #expect(logs.first?.attempts.map(\.status) == [.invalidResponse])
    #expect(logs.first?.finalUpstream == "invalid")
}

extension Data {
    static func makeCNameResponse(for request: Data, cname: String) throws -> Data {
        let query = try DNSMessage.parse(request)
        var data = Data()
        data.appendUInt16(query.id)
        data.appendUInt16(0x8180)
        data.appendUInt16(1)
        data.appendUInt16(1)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendQName(query.question.name)
        data.appendUInt16(query.question.type)
        data.appendUInt16(query.question.qclass)
        data.appendUInt16(0xc00c)
        data.appendUInt16(5)
        data.appendUInt16(1)
        data.appendUInt32(60)

        var rdata = Data()
        rdata.appendQName(cname)
        data.appendUInt16(UInt16(rdata.count))
        data.append(rdata)
        return data
    }

    static func makeAResponse(for request: Data, ip: String) throws -> Data {
        let query = try DNSMessage.parse(request)
        let octets = ip.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { throw DNSMessageError.malformedName }

        var data = Data()
        data.appendUInt16(query.id)
        data.appendUInt16(0x8180)
        data.appendUInt16(1)
        data.appendUInt16(1)
        data.appendUInt16(0)
        data.appendUInt16(0)
        data.appendQName(query.question.name)
        data.appendUInt16(query.question.type)
        data.appendUInt16(query.question.qclass)
        data.appendUInt16(0xc00c)
        data.appendUInt16(1)
        data.appendUInt16(1)
        data.appendUInt32(60)
        data.appendUInt16(4)
        data.append(contentsOf: octets)
        return data
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
