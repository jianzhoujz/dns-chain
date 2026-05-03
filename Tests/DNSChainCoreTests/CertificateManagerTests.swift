import Testing
import Foundation
@testable import DNSChainCore

@Test
func generatesLocalCertificates() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let paths = CertificatePaths(
        directory: directory,
        rootCertificate: directory.appendingPathComponent("root-ca.pem"),
        rootKey: directory.appendingPathComponent("root-ca.key"),
        serverCertificate: directory.appendingPathComponent("localhost.crt"),
        serverKey: directory.appendingPathComponent("localhost.key")
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    let manager = CertificateManager(paths: paths)
    try manager.ensureGenerated()

    let root = try String(contentsOf: paths.rootCertificate, encoding: .utf8)
    let server = try String(contentsOf: paths.serverCertificate, encoding: .utf8)
    #expect(root.contains("BEGIN CERTIFICATE"))
    #expect(server.contains("BEGIN CERTIFICATE"))
    #expect(FileManager.default.fileExists(atPath: paths.rootKey.path))
    #expect(FileManager.default.fileExists(atPath: paths.serverKey.path))
}
