import Foundation

public actor SystemBypassStore {
    private let fileURL: URL
    private var domains: Set<String> = []
    private var loaded = false

    public init(fileURL: URL = SystemBypassStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    public static func defaultFileURL() -> URL {
        ConfigStore.defaultConfigURL()
            .deletingLastPathComponent()
            .appendingPathComponent("system-bypass.txt")
    }

    public func contains(_ domain: String) async -> Bool {
        await loadIfNeeded()
        let normalized = DNSMessage.normalizeName(domain)
        return domains.contains { entry in
            normalized == entry || normalized.hasSuffix("." + entry)
        }
    }

    public func record(_ domain: String) async {
        await loadIfNeeded()
        let normalized = DNSMessage.normalizeName(domain)
        guard !normalized.isEmpty, !domains.contains(normalized) else { return }
        domains.insert(normalized)
        do {
            try persist()
        } catch {
            // Runtime learning should not fail DNS resolution.
        }
    }

    public func allDomains() async -> [String] {
        await loadIfNeeded()
        return domains.sorted()
    }

    public func clear() async {
        domains.removeAll()
        loaded = true
        try? persist()
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else {
            return
        }

        domains = Set(text
            .split(whereSeparator: \.isNewline)
            .map { line in
                line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            }
            .map { DNSMessage.normalizeName(String($0)) }
            .filter { !$0.isEmpty }
        )
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = domains.sorted().joined(separator: "\n") + (domains.isEmpty ? "" : "\n")
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
