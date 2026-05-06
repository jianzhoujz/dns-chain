import Foundation

public enum UpstreamType: String, Codable, Sendable {
    case system
    case doh
    case plainDNS = "plain_dns"
}

public struct ServerConfig: Codable, Equatable, Sendable {
    public var listenHost: String
    public var listenPort: Int
    public var dohPath: String

    public init(listenHost: String = "127.0.0.1", listenPort: Int = 8053, dohPath: String = "/dns-query") {
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.dohPath = dohPath
    }

    enum CodingKeys: String, CodingKey {
        case listenHost = "listen_host"
        case listenPort = "listen_port"
        case dohPath = "doh_path"
    }
}

public struct DNSUpstreamConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var type: UpstreamType
    public var enabled: Bool
    public var url: URL?
    public var servers: [String]?
    public var port: Int?
    public var timeoutMs: Int
    public var isPreset: Bool

    public init(
        id: String,
        name: String,
        type: UpstreamType,
        enabled: Bool = true,
        url: URL? = nil,
        servers: [String]? = nil,
        port: Int? = nil,
        timeoutMs: Int? = nil,
        isPreset: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.url = url
        self.servers = servers
        self.port = port
        self.timeoutMs = timeoutMs ?? (type == .plainDNS ? 1500 : 2000)
        self.isPreset = isPreset
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case type
        case enabled
        case url
        case servers
        case port
        case timeoutMs = "timeout_ms"
        case isPreset = "is_preset"
    }
}

public struct FallbackConfig: Codable, Equatable, Sendable {
    public var timeout: Bool
    public var networkError: Bool
    public var servfail: Bool
    public var refused: Bool
    public var emptyAnswer: Bool
    public var blockedIP: Bool
    public var blockedCNAME: Bool
    public var nxdomain: Bool
    public var invalidResponse: Bool

    public init(
        timeout: Bool = true,
        networkError: Bool = true,
        servfail: Bool = true,
        refused: Bool = true,
        emptyAnswer: Bool = false,
        blockedIP: Bool = true,
        blockedCNAME: Bool = true,
        nxdomain: Bool = false,
        invalidResponse: Bool = true
    ) {
        self.timeout = timeout
        self.networkError = networkError
        self.servfail = servfail
        self.refused = refused
        self.emptyAnswer = emptyAnswer
        self.blockedIP = blockedIP
        self.blockedCNAME = blockedCNAME
        self.nxdomain = nxdomain
        self.invalidResponse = invalidResponse
    }

    enum CodingKeys: String, CodingKey {
        case timeout
        case networkError = "network_error"
        case servfail
        case refused
        case emptyAnswer = "empty_answer"
        case blockedIP = "blocked_ip"
        case blockedCNAME = "blocked_cname"
        case nxdomain
        case invalidResponse = "invalid_response"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timeout = try container.decodeIfPresent(Bool.self, forKey: .timeout) ?? true
        self.networkError = try container.decodeIfPresent(Bool.self, forKey: .networkError) ?? true
        self.servfail = try container.decodeIfPresent(Bool.self, forKey: .servfail) ?? true
        self.refused = try container.decodeIfPresent(Bool.self, forKey: .refused) ?? true
        self.emptyAnswer = try container.decodeIfPresent(Bool.self, forKey: .emptyAnswer) ?? false
        self.blockedIP = try container.decodeIfPresent(Bool.self, forKey: .blockedIP) ?? true
        self.blockedCNAME = try container.decodeIfPresent(Bool.self, forKey: .blockedCNAME) ?? true
        self.nxdomain = try container.decodeIfPresent(Bool.self, forKey: .nxdomain) ?? false
        self.invalidResponse = try container.decodeIfPresent(Bool.self, forKey: .invalidResponse) ?? true
    }
}

public struct BlockedAnswersConfig: Codable, Equatable, Sendable {
    public var ipCIDRs: [String]
    public var cnameSuffixes: [String]

    public init(ipCIDRs: [String] = [], cnameSuffixes: [String] = []) {
        self.ipCIDRs = ipCIDRs
        self.cnameSuffixes = cnameSuffixes
    }

    enum CodingKeys: String, CodingKey {
        case ipCIDRs = "ip_cidrs"
        case cnameSuffixes = "cname_suffixes"
    }
}

public struct CacheConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var maxTTLSeconds: Int
    public var minTTLSeconds: Int
    public var negativeTTLSeconds: Int

    public init(enabled: Bool = true, maxTTLSeconds: Int = 300, minTTLSeconds: Int = 5, negativeTTLSeconds: Int = 30) {
        self.enabled = enabled
        self.maxTTLSeconds = maxTTLSeconds
        self.minTTLSeconds = minTTLSeconds
        self.negativeTTLSeconds = negativeTTLSeconds
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case maxTTLSeconds = "max_ttl_seconds"
        case minTTLSeconds = "min_ttl_seconds"
        case negativeTTLSeconds = "negative_ttl_seconds"
    }
}

public struct LoggingConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var maxEntries: Int

    public init(enabled: Bool = true, maxEntries: Int = 1000) {
        self.enabled = enabled
        self.maxEntries = maxEntries
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case maxEntries = "max_entries"
    }
}

public struct DNSChainConfig: Codable, Equatable, Sendable {
    public var server: ServerConfig
    public var dnsChain: [DNSUpstreamConfig]
    public var fallbackWhen: FallbackConfig
    public var blockedAnswers: BlockedAnswersConfig
    public var protectedSuffixes: [String]
    public var cache: CacheConfig
    public var logging: LoggingConfig

    public init(
        server: ServerConfig = ServerConfig(),
        dnsChain: [DNSUpstreamConfig] = PresetLibrary.defaultChain,
        fallbackWhen: FallbackConfig = FallbackConfig(),
        blockedAnswers: BlockedAnswersConfig = BlockedAnswersConfig(),
        protectedSuffixes: [String] = [".local", ".lan", ".home.arpa", ".corp", ".internal"],
        cache: CacheConfig = CacheConfig(),
        logging: LoggingConfig = LoggingConfig()
    ) {
        self.server = server
        self.dnsChain = dnsChain
        self.fallbackWhen = fallbackWhen
        self.blockedAnswers = blockedAnswers
        self.protectedSuffixes = protectedSuffixes
        self.cache = cache
        self.logging = logging
    }

    enum CodingKeys: String, CodingKey {
        case server
        case dnsChain = "dns_chain"
        case fallbackWhen = "fallback_when"
        case blockedAnswers = "blocked_answers"
        case protectedSuffixes = "protected_suffixes"
        case cache
        case logging
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.server = try container.decodeIfPresent(ServerConfig.self, forKey: .server) ?? ServerConfig()
        self.dnsChain = try container.decodeIfPresent([DNSUpstreamConfig].self, forKey: .dnsChain) ?? PresetLibrary.defaultChain
        self.fallbackWhen = try container.decodeIfPresent(FallbackConfig.self, forKey: .fallbackWhen) ?? FallbackConfig()
        self.blockedAnswers = try container.decodeIfPresent(BlockedAnswersConfig.self, forKey: .blockedAnswers) ?? BlockedAnswersConfig()
        self.protectedSuffixes = try container.decodeIfPresent([String].self, forKey: .protectedSuffixes) ?? [".local", ".lan", ".home.arpa", ".corp", ".internal"]
        self.cache = try container.decodeIfPresent(CacheConfig.self, forKey: .cache) ?? CacheConfig()
        self.logging = try container.decodeIfPresent(LoggingConfig.self, forKey: .logging) ?? LoggingConfig()
    }
}

public enum PresetLibrary {
    public static let presets: [DNSUpstreamConfig] = [
        DNSUpstreamConfig(id: "system", name: "系统 DNS", type: .system, isPreset: true),
        DNSUpstreamConfig(id: "alidns_doh", name: "阿里云 DoH", type: .doh, url: URL(string: "https://dns.alidns.com/dns-query"), isPreset: true),
        DNSUpstreamConfig(id: "dnspod_doh", name: "腾讯 DNSPod DoH", type: .doh, url: URL(string: "https://doh.pub/dns-query"), isPreset: true),
        DNSUpstreamConfig(id: "alidns_plain", name: "阿里云 DNS", type: .plainDNS, servers: ["223.5.5.5", "223.6.6.6"], port: 53, isPreset: true),
        DNSUpstreamConfig(id: "dnspod_plain", name: "腾讯 DNSPod DNS", type: .plainDNS, servers: ["119.29.29.29"], port: 53, isPreset: true),
        DNSUpstreamConfig(id: "cloudflare_doh", name: "Cloudflare DoH", type: .doh, enabled: false, url: URL(string: "https://cloudflare-dns.com/dns-query"), isPreset: true),
        DNSUpstreamConfig(id: "cloudflare_plain", name: "Cloudflare DNS", type: .plainDNS, enabled: false, servers: ["1.1.1.1", "1.0.0.1"], port: 53, isPreset: true),
        DNSUpstreamConfig(id: "google_doh", name: "Google Public DNS DoH", type: .doh, enabled: false, url: URL(string: "https://dns.google/dns-query"), isPreset: true),
        DNSUpstreamConfig(id: "google_plain", name: "Google Public DNS", type: .plainDNS, enabled: false, servers: ["8.8.8.8", "8.8.4.4"], port: 53, isPreset: true)
    ]

    public static let defaultChain: [DNSUpstreamConfig] = Array(presets.prefix(5))
}
