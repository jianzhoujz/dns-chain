import Foundation

public struct SystemResolver: Equatable, Sendable {
    public var domain: String?
    public var nameservers: [String]
    public var port: Int
}

public enum SystemDNSParser {
    public static func parseScutilDNS(_ output: String) -> [SystemResolver] {
        var resolvers: [SystemResolver] = []
        var currentDomain: String?
        var currentServers: [String] = []
        var currentPort = 53

        func flush() {
            guard !currentServers.isEmpty else { return }
            resolvers.append(SystemResolver(domain: currentDomain, nameservers: currentServers, port: currentPort))
            currentDomain = nil
            currentServers = []
            currentPort = 53
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") {
                flush()
                continue
            }
            if line.hasPrefix("domain") {
                currentDomain = value(afterColon: line)
            } else if line.hasPrefix("nameserver") {
                if let server = value(afterColon: line) {
                    currentServers.append(server)
                }
            } else if line.hasPrefix("port"), let portValue = value(afterColon: line), let port = Int(portValue) {
                currentPort = port
            }
        }
        flush()
        return resolvers
    }

    public static func bestResolver(for domain: String, resolvers: [SystemResolver]) -> SystemResolver? {
        let normalized = DNSMessage.normalizeName(domain)
        let domainMatches = resolvers.filter { resolver in
            guard let suffix = resolver.domain.map(DNSMessage.normalizeName) else { return false }
            return normalized == suffix || normalized.hasSuffix("." + suffix)
        }
        if let best = domainMatches.max(by: { ($0.domain?.count ?? 0) < ($1.domain?.count ?? 0) }) {
            return best
        }
        return resolvers.first(where: { $0.domain == nil }) ?? resolvers.first
    }

    private static func value(afterColon line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
}

public struct SystemDNSUpstream: DNSUpstream {
    public let id: String
    public let name: String
    public let type: UpstreamType = .system
    public let timeoutMs: Int

    public init(id: String, name: String, timeoutMs: Int = 1500) {
        self.id = id
        self.name = name
        self.timeoutMs = timeoutMs
    }

    public func query(_ request: Data) async throws -> UpstreamResponse {
        let message = try DNSMessage.parse(request)
        let resolvers = try await loadSystemResolvers()
        guard let resolver = SystemDNSParser.bestResolver(for: message.question.name, resolvers: resolvers) else {
            throw UpstreamError.network("No system resolver found")
        }
        let plain = PlainDNSUpstream(id: id, name: name, servers: resolver.nameservers, port: resolver.port, timeoutMs: timeoutMs)
        return try await plain.query(request)
    }

    private func loadSystemResolvers() async throws -> [SystemResolver] {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = ["--dns"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                continuation.resume(returning: SystemDNSParser.parseScutilDNS(output))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
