import Foundation

public struct CacheKey: Hashable, Sendable {
    public var qname: String
    public var qtype: UInt16
    public var qclass: UInt16

    public init(question: DNSQuestion) {
        self.qname = question.normalizedName
        self.qtype = question.type
        self.qclass = question.qclass
    }
}

public struct CacheEntry: Sendable {
    public var response: Data
    public var expiresAt: Date
    public var upstreamID: String
}

public actor DNSCacheStore {
    private var entries: [CacheKey: CacheEntry] = [:]

    public init() {}

    public func value(for key: CacheKey, now: Date = Date()) -> CacheEntry? {
        guard let entry = entries[key] else { return nil }
        if entry.expiresAt <= now {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry
    }

    public func insert(response: DNSMessage, upstreamID: String, config: CacheConfig, now: Date = Date()) {
        guard config.enabled else { return }
        let ttl: Int
        if response.rcode == .nxDomain {
            ttl = config.negativeTTLSeconds
        } else if let minTTL = response.minimumAnswerTTL {
            ttl = min(max(Int(minTTL), config.minTTLSeconds), config.maxTTLSeconds)
        } else {
            return
        }
        entries[CacheKey(question: response.question)] = CacheEntry(
            response: response.raw,
            expiresAt: now.addingTimeInterval(TimeInterval(ttl)),
            upstreamID: upstreamID
        )
    }

    public func clear() {
        entries.removeAll()
    }
}
