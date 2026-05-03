import Foundation

public final class ConfigStore: @unchecked Sendable {
    public let configURL: URL
    public let legacyConfigURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(configURL: URL = ConfigStore.defaultConfigURL(), legacyConfigURL: URL = ConfigStore.legacyConfigURL()) {
        self.configURL = configURL
        self.legacyConfigURL = legacyConfigURL
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
    }

    public static func defaultConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/dns-chain", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public static func legacyConfigURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DNS Chain", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public func loadOrCreateDefault() throws -> DNSChainConfig {
        if FileManager.default.fileExists(atPath: configURL.path) {
            let data = try Data(contentsOf: configURL)
            return try decoder.decode(DNSChainConfig.self, from: data)
        }
        if FileManager.default.fileExists(atPath: legacyConfigURL.path) {
            let data = try Data(contentsOf: legacyConfigURL)
            let config = try decoder.decode(DNSChainConfig.self, from: data)
            try save(config)
            return config
        }
        let config = DNSChainConfig()
        try save(config)
        return config
    }

    public func save(_ config: DNSChainConfig) throws {
        let dir = configURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(config)
        try data.write(to: configURL, options: [.atomic])
    }
}
