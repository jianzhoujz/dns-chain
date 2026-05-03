import Foundation

public enum UpstreamError: Error, Sendable {
    case invalidConfiguration(String)
    case timeout
    case network(String)
    case invalidResponse
}

public struct UpstreamResponse: Sendable {
    public var message: DNSMessage
    public var attempt: AttemptLog

    public init(message: DNSMessage, attempt: AttemptLog) {
        self.message = message
        self.attempt = attempt
    }
}

public protocol DNSUpstream: Sendable {
    var id: String { get }
    var name: String { get }
    var type: UpstreamType { get }

    func query(_ request: Data) async throws -> UpstreamResponse
}

public enum UpstreamFactory {
    public static func make(config: DNSUpstreamConfig) throws -> any DNSUpstream {
        switch config.type {
        case .doh:
            guard let url = config.url else {
                throw UpstreamError.invalidConfiguration("DoH upstream missing URL")
            }
            return DoHUpstream(id: config.id, name: config.name, url: url, timeoutMs: config.timeoutMs)
        case .plainDNS:
            guard let servers = config.servers, !servers.isEmpty else {
                throw UpstreamError.invalidConfiguration("Plain DNS upstream missing servers")
            }
            return PlainDNSUpstream(
                id: config.id,
                name: config.name,
                servers: servers,
                port: config.port ?? 53,
                timeoutMs: config.timeoutMs
            )
        case .system:
            return SystemDNSUpstream(id: config.id, name: config.name, timeoutMs: config.timeoutMs)
        }
    }

    public static func makeAll(config: DNSChainConfig) -> [any DNSUpstream] {
        config.dnsChain
            .filter(\.enabled)
            .compactMap { try? make(config: $0) }
    }
}

func measureLatency<T>(_ operation: () async throws -> T) async throws -> (T, Int) {
    let start = ContinuousClock.now
    let result = try await operation()
    let elapsed = start.duration(to: ContinuousClock.now)
    let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    return (result, ms)
}
