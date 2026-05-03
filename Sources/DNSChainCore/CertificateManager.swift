import Foundation
import Crypto
import SwiftASN1
import X509

public enum CertificateState: String, Sendable {
    case missing
    case present
    case trusted
}

public struct CertificatePaths: Sendable {
    public var directory: URL
    public var rootCertificate: URL
    public var rootKey: URL
    public var serverCertificate: URL
    public var serverKey: URL

    public static func `default`() -> CertificatePaths {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DNSChain/certs", isDirectory: true)
        return make(directory: directory)
    }

    public static func legacyDefault() -> CertificatePaths {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DNS Chain/certs", isDirectory: true)
        return make(directory: directory)
    }

    private static func make(directory: URL) -> CertificatePaths {
        return CertificatePaths(
            directory: directory,
            rootCertificate: directory.appendingPathComponent("root-ca.pem"),
            rootKey: directory.appendingPathComponent("root-ca.key"),
            serverCertificate: directory.appendingPathComponent("localhost.crt"),
            serverKey: directory.appendingPathComponent("localhost.key")
        )
    }
}

public final class CertificateManager: @unchecked Sendable {
    public let paths: CertificatePaths

    public init(paths: CertificatePaths = .default()) {
        self.paths = paths
        try? Self.migrateLegacyCertificates(to: paths)
    }

    private static func migrateLegacyCertificates(to paths: CertificatePaths) throws {
        let legacy = CertificatePaths.legacyDefault()
        let fm = FileManager.default
        guard legacy.directory.path != paths.directory.path,
              fm.fileExists(atPath: legacy.directory.path),
              !fm.fileExists(atPath: paths.directory.path) else {
            return
        }
        try fm.createDirectory(at: paths.directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: legacy.directory, to: paths.directory)
    }

    public func state() -> CertificateState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.rootCertificate.path),
              fm.fileExists(atPath: paths.rootKey.path),
              fm.fileExists(atPath: paths.serverCertificate.path),
              fm.fileExists(atPath: paths.serverKey.path) else {
            return .missing
        }
        return isRootTrusted() ? .trusted : .present
    }

    public func ensureGenerated() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: paths.rootCertificate.path) ||
              !fm.fileExists(atPath: paths.rootKey.path) ||
              !fm.fileExists(atPath: paths.serverCertificate.path) ||
              !fm.fileExists(atPath: paths.serverKey.path) else {
            return
        }

        let now = Date()
        let rootKey = P256.Signing.PrivateKey()
        let serverKey = P256.Signing.PrivateKey()
        let rootName = try DistinguishedName {
            CommonName("DNS Chain Local Root CA")
        }
        let serverName = try DistinguishedName {
            CommonName("localhost")
        }

        let rootCertificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(rootKey.publicKey),
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(10 * 365 * 24 * 60 * 60),
            issuer: rootName,
            subject: rootName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: .init(rootKey)
        )

        let serverCertificate = try Certificate(
            version: .v3,
            serialNumber: .init(),
            publicKey: .init(serverKey.publicKey),
            notValidBefore: now,
            notValidAfter: now.addingTimeInterval(397 * 24 * 60 * 60),
            issuer: rootName,
            subject: serverName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames([
                    .dnsName("localhost"),
                    .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1][...])),
                    .ipAddress(ASN1OctetString(contentBytes: ([UInt8](repeating: 0, count: 15) + [1])[...]))
                ])
            },
            issuerPrivateKey: .init(rootKey)
        )

        try rootCertificate.serializeAsPEM().pemString.write(to: paths.rootCertificate, atomically: true, encoding: .utf8)
        try rootKey.pemRepresentation.write(to: paths.rootKey, atomically: true, encoding: .utf8)
        try serverCertificate.serializeAsPEM().pemString.write(to: paths.serverCertificate, atomically: true, encoding: .utf8)
        try serverKey.pemRepresentation.write(to: paths.serverKey, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.rootKey.path)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.serverKey.path)
    }

    public func installRootCertificate() throws {
        try ensureGenerated()
        try run("/usr/bin/security", [
            "add-trusted-cert",
            "-r", "trustRoot",
            paths.rootCertificate.path
        ])
    }

    public func uninstallRootCertificate() throws {
        try run("/usr/bin/security", [
            "remove-trusted-cert",
            paths.rootCertificate.path
        ])
    }

    private func isRootTrusted() -> Bool {
        (try? runCapturing("/usr/bin/security", [
            "find-certificate",
            "-c", "DNS Chain Local Root CA"
        ])) != nil
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], elevated: Bool = false) throws -> String {
        if elevated {
            let script = ([executable] + arguments).map { shellQuote($0) }.joined(separator: " ")
            return try runCapturing("/usr/bin/osascript", [
                "-e",
                "on run argv",
                "-e",
                "do shell script (item 1 of argv) with administrator privileges",
                "-e",
                "end run",
                script
            ])
        }
        return try runCapturing(executable, arguments)
    }

    private func runCapturing(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpstreamError.network(err.isEmpty ? out : err)
        }
        return out
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
