import Foundation

public struct DoHUpstream: DNSUpstream {
    public let id: String
    public let name: String
    public let type: UpstreamType = .doh
    public let url: URL
    public let timeoutMs: Int

    public init(id: String, name: String, url: URL, timeoutMs: Int = 2000) {
        self.id = id
        self.name = name
        self.url = url
        self.timeoutMs = timeoutMs
    }

    public func query(_ request: Data) async throws -> UpstreamResponse {
        do {
            let (data, latency) = try await measureLatency {
                var urlRequest = URLRequest(url: url)
                urlRequest.httpMethod = "POST"
                urlRequest.timeoutInterval = TimeInterval(timeoutMs) / 1000
                urlRequest.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
                urlRequest.setValue("application/dns-message", forHTTPHeaderField: "Accept")
                urlRequest.httpBody = request
                let (data, response) = try await URLSession.shared.data(for: urlRequest)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw UpstreamError.network("DoH upstream returned non-2xx")
                }
                return data
            }
            let message = try DNSMessage.parse(data)
            return UpstreamResponse(
                message: message,
                attempt: AttemptLog(upstreamID: id, upstreamName: name, status: .success, latencyMs: latency)
            )
        } catch let error as UpstreamError {
            throw error
        } catch is CancellationError {
            throw UpstreamError.timeout
        } catch {
            throw UpstreamError.network(error.localizedDescription)
        }
    }
}
