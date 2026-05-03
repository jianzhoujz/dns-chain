import Foundation

public enum LoginItemError: Error, Sendable {
    case missingExecutable
}

public final class LoginItemManager: @unchecked Sendable {
    public static let shared = LoginItemManager()

    private let label = "com.dns-chain.launch"
    private let fileManager = FileManager.default

    public init() {}

    public var launchAgentURL: URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    public func isEnabled() -> Bool {
        fileManager.fileExists(atPath: launchAgentURL.path)
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try installLaunchAgent()
        } else {
            try removeLaunchAgent()
        }
    }

    private func installLaunchAgent() throws {
        guard let executableURL = Bundle.main.executableURL else {
            throw LoginItemError.missingExecutable
        }
        let launchAgents = launchAgentURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executableURL.path],
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": "/tmp/dns-chain.launchd.out.log",
            "StandardErrorPath": "/tmp/dns-chain.launchd.err.log"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: [.atomic])
    }

    private func removeLaunchAgent() throws {
        if fileManager.fileExists(atPath: launchAgentURL.path) {
            try fileManager.removeItem(at: launchAgentURL)
        }
    }
}
