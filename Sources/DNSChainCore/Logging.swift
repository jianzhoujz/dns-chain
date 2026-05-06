import Foundation

public enum AttemptStatus: String, Codable, Sendable {
    case success
    case timeout
    case networkError = "network_error"
    case servfail
    case refused
    case nxdomain
    case emptyAnswer = "empty_answer"
    case blockedIP = "blocked_ip"
    case blockedCNAME = "blocked_cname"
    case protected
    case skippedSystem = "skipped_system"
    case invalidResponse = "invalid_response"
}

public struct AttemptLog: Codable, Equatable, Sendable {
    public var upstreamID: String
    public var upstreamName: String
    public var status: AttemptStatus
    public var latencyMs: Int
    public var detail: String?

    public init(upstreamID: String, upstreamName: String, status: AttemptStatus, latencyMs: Int, detail: String? = nil) {
        self.upstreamID = upstreamID
        self.upstreamName = upstreamName
        self.status = status
        self.latencyMs = latencyMs
        self.detail = detail
    }
}

public enum QueryResult: String, Codable, Sendable {
    case success
    case fallback
    case failed
    case protected
    case cached
}

public struct QueryLog: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var domain: String
    public var qtype: UInt16
    public var client: String
    public var result: QueryResult
    public var finalUpstream: String?
    public var attempts: [AttemptLog]
    public var rcode: DNSRCode?
    public var answers: [DNSAnswer]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        domain: String,
        qtype: UInt16,
        client: String = "127.0.0.1",
        result: QueryResult,
        finalUpstream: String?,
        attempts: [AttemptLog],
        rcode: DNSRCode?,
        answers: [DNSAnswer]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.qtype = qtype
        self.client = client
        self.result = result
        self.finalUpstream = finalUpstream
        self.attempts = attempts
        self.rcode = rcode
        self.answers = answers
    }
}

public actor QueryLogStore {
    private var entries: [QueryLog] = []
    private var maxEntries: Int

    public init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
    }

    public func append(_ entry: QueryLog) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func recent(limit: Int = 100) -> [QueryLog] {
        Array(entries.suffix(limit).reversed())
    }

    public func clear() {
        entries.removeAll()
    }

    public func configure(maxEntries: Int) {
        self.maxEntries = maxEntries
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
}
