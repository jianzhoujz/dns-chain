import Foundation
import Darwin

public struct IPAddressCIDR: Equatable, Sendable {
    public let address: [UInt8]
    public let prefixLength: Int

    public init?(_ raw: String) {
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        let ip = parts[0]
        if ip.contains(":") {
            guard let bytes = IPAddressCIDR.parseIPv6(ip), (0...128).contains(prefix) else { return nil }
            self.address = bytes
            self.prefixLength = prefix
        } else {
            guard let bytes = IPAddressCIDR.parseIPv4(ip), (0...32).contains(prefix) else { return nil }
            self.address = bytes
            self.prefixLength = prefix
        }
    }

    public func contains(_ ip: String) -> Bool {
        let candidate: [UInt8]?
        if ip.contains(":") {
            candidate = IPAddressCIDR.parseIPv6(ip)
        } else {
            candidate = IPAddressCIDR.parseIPv4(ip)
        }
        guard let candidate, candidate.count == address.count else { return false }
        let fullBytes = prefixLength / 8
        let partialBits = prefixLength % 8
        if fullBytes > 0, candidate[0..<fullBytes] != address[0..<fullBytes] {
            return false
        }
        if partialBits == 0 {
            return true
        }
        let mask = UInt8(0xff << (8 - partialBits))
        return (candidate[fullBytes] & mask) == (address[fullBytes] & mask)
    }

    private static func parseIPv4(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return parts.compactMap { UInt8($0) }.count == 4 ? parts.compactMap { UInt8($0) } : nil
    }

    private static func parseIPv6(_ ip: String) -> [UInt8]? {
        var addr = in6_addr()
        let result = ip.withCString { inet_pton(AF_INET6, $0, &addr) }
        guard result == 1 else { return nil }
        return withUnsafeBytes(of: addr) { Array($0) }
    }
}

public struct BlockedAnswerMatcher: Sendable {
    public let cidrs: [IPAddressCIDR]
    public let cnameSuffixes: [String]

    public init(config: BlockedAnswersConfig) {
        self.cidrs = config.ipCIDRs.compactMap(IPAddressCIDR.init)
        self.cnameSuffixes = config.cnameSuffixes.map {
            $0.lowercased().hasPrefix(".") ? $0.lowercased() : "." + $0.lowercased()
        }
    }

    public func blockedIP(in answers: [DNSAnswer]) -> String? {
        for answer in answers where answer.type == .a || answer.type == .aaaa {
            if cidrs.contains(where: { $0.contains(answer.value) }) {
                return answer.value
            }
        }
        return nil
    }

    public func blockedCNAME(in answers: [DNSAnswer]) -> String? {
        for answer in answers where answer.type == .cname {
            let value = DNSMessage.normalizeName(answer.value)
            if cnameSuffixes.contains(where: { value.hasSuffix(DNSMessage.normalizeName($0)) }) {
                return answer.value
            }
        }
        return nil
    }
}
