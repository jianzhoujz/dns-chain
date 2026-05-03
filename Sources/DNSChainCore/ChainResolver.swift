import Foundation

public enum ResolveError: Error, Sendable {
    case invalidRequest
}

public struct Classification: Sendable {
    public var status: AttemptStatus
    public var shouldFallback: Bool
    public var detail: String?
}

public actor ChainResolver {
    private var config: DNSChainConfig
    private var upstreams: [any DNSUpstream]
    private let cache: DNSCacheStore
    private let logs: QueryLogStore

    public init(
        config: DNSChainConfig,
        cache: DNSCacheStore = DNSCacheStore(),
        logs: QueryLogStore? = nil,
        upstreams: [any DNSUpstream]? = nil
    ) {
        self.config = config
        self.upstreams = upstreams ?? UpstreamFactory.makeAll(config: config)
        self.cache = cache
        self.logs = logs ?? QueryLogStore(maxEntries: config.logging.maxEntries)
    }

    public func updateConfig(_ config: DNSChainConfig) {
        self.config = config
        self.upstreams = UpstreamFactory.makeAll(config: config)
        Task {
            await logs.configure(maxEntries: config.logging.maxEntries)
            await cache.clear()
        }
    }

    public func recentLogs(limit: Int = 100) async -> [QueryLog] {
        await logs.recent(limit: limit)
    }

    public func resolve(_ request: Data, client: String = "127.0.0.1") async throws -> Data {
        let parsedRequest: DNSMessage
        do {
            parsedRequest = try DNSMessage.parse(request)
        } catch {
            throw ResolveError.invalidRequest
        }

        let cacheKey = CacheKey(question: parsedRequest.question)
        if let cached = await cache.value(for: cacheKey) {
            await appendLog(
                request: parsedRequest,
                client: client,
                result: .cached,
                finalUpstream: cached.upstreamID,
                attempts: [],
                response: try? DNSMessage.parse(cached.response)
            )
            return cached.response
        }

        let protected = isProtected(parsedRequest.question.name)
        let candidates = protected ? upstreams.filter { $0.type == .system } : upstreams
        var attempts: [AttemptLog] = []
        var sawFallback = false
        var lastNoDataResponse: DNSMessage?
        var lastNoDataUpstreamID: String?

        for upstream in candidates {
            do {
                let response = try await upstream.query(request)
                let classification = classify(response.message)
                var attempt = response.attempt
                attempt.status = classification.status
                attempt.detail = classification.detail ?? attempt.detail
                attempts.append(attempt)

                if classification.shouldFallback {
                    sawFallback = true
                    if classification.status == .emptyAnswer || classification.status == .nxdomain {
                        lastNoDataResponse = response.message
                        lastNoDataUpstreamID = upstream.id
                    }
                    continue
                }

                await cache.insert(response: response.message, upstreamID: upstream.id, config: config.cache)
                await appendLog(
                    request: parsedRequest,
                    client: client,
                    result: protected ? .protected : (sawFallback ? .fallback : .success),
                    finalUpstream: upstream.id,
                    attempts: attempts,
                    response: response.message
                )
                return response.message.raw
            } catch {
                let status = statusForError(error)
                attempts.append(AttemptLog(
                    upstreamID: upstream.id,
                    upstreamName: upstream.name,
                    status: status,
                    latencyMs: 0,
                    detail: String(describing: error)
                ))
                sawFallback = true
                continue
            }
        }

        if let lastNoDataResponse {
            await cache.insert(response: lastNoDataResponse, upstreamID: lastNoDataUpstreamID ?? "unknown", config: config.cache)
            await appendLog(
                request: parsedRequest,
                client: client,
                result: protected ? .protected : .fallback,
                finalUpstream: lastNoDataUpstreamID,
                attempts: attempts,
                response: lastNoDataResponse
            )
            return lastNoDataResponse.raw
        }

        let failure = DNSMessage.makeErrorResponse(for: request, rcode: .servFail)
        await appendLog(
            request: parsedRequest,
            client: client,
            result: protected ? .protected : .failed,
            finalUpstream: nil,
            attempts: attempts,
            response: try? DNSMessage.parse(failure)
        )
        return failure
    }

    public func testUpstream(_ upstreamConfig: DNSUpstreamConfig, domain: String = "example.com", qtype: UInt16 = 1) async throws -> AttemptLog {
        let upstream = try UpstreamFactory.make(config: upstreamConfig)
        let request = Data.makeQuery(name: domain, type: qtype)
        let response = try await upstream.query(request)
        var attempt = response.attempt
        let classification = classify(response.message)
        attempt.status = classification.status
        attempt.detail = classification.detail ?? attempt.detail
        return attempt
    }

    private func classify(_ response: DNSMessage) -> Classification {
        let fallback = config.fallbackWhen
        let matcher = BlockedAnswerMatcher(config: config.blockedAnswers)

        switch response.rcode {
        case .noError:
            if let ip = matcher.blockedIP(in: response.answers), fallback.blockedIP {
                return Classification(status: .blockedIP, shouldFallback: true, detail: ip)
            }
            if let cname = matcher.blockedCNAME(in: response.answers), fallback.blockedCNAME {
                return Classification(status: .blockedCNAME, shouldFallback: true, detail: cname)
            }
            if response.answers.isEmpty {
                return Classification(status: .emptyAnswer, shouldFallback: fallback.emptyAnswer, detail: nil)
            }
            return Classification(status: .success, shouldFallback: false, detail: nil)
        case .servFail:
            return Classification(status: .servfail, shouldFallback: fallback.servfail, detail: nil)
        case .refused:
            return Classification(status: .refused, shouldFallback: fallback.refused, detail: nil)
        case .nxDomain:
            return Classification(status: .nxdomain, shouldFallback: fallback.nxdomain, detail: nil)
        default:
            return Classification(status: .invalidResponse, shouldFallback: true, detail: "rcode=\(response.rcode)")
        }
    }

    private func statusForError(_ error: Error) -> AttemptStatus {
        if case UpstreamError.timeout = error {
            return .timeout
        }
        if case UpstreamError.invalidResponse = error {
            return .invalidResponse
        }
        return .networkError
    }

    private func isProtected(_ domain: String) -> Bool {
        let normalized = DNSMessage.normalizeName(domain)
        return config.protectedSuffixes.contains { suffix in
            let normalizedSuffix = DNSMessage.normalizeName(suffix)
            return normalized == normalizedSuffix || normalized.hasSuffix("." + normalizedSuffix)
        }
    }

    private func appendLog(
        request: DNSMessage,
        client: String,
        result: QueryResult,
        finalUpstream: String?,
        attempts: [AttemptLog],
        response: DNSMessage?
    ) async {
        guard config.logging.enabled else { return }
        await logs.append(QueryLog(
            domain: DNSMessage.normalizeName(request.question.name),
            qtype: request.question.type,
            client: client,
            result: result,
            finalUpstream: finalUpstream,
            attempts: attempts,
            rcode: response?.rcode,
            answers: response?.answers ?? []
        ))
    }
}
