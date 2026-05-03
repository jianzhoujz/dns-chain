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
