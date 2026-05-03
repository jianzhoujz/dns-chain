import Darwin
import Foundation

public enum ProxyRequestStatus: String, Codable, Sendable {
    case connecting
    case tunnel
    case forwarding
    case closed
    case failed
}

public struct ProxyRequestLog: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var method: String
    public var targetHost: String
    public var targetPort: Int
    public var status: ProxyRequestStatus
    public var bytesUp: Int
    public var bytesDown: Int
    public var detail: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        targetHost: String,
        targetPort: Int,
        status: ProxyRequestStatus,
        bytesUp: Int = 0,
        bytesDown: Int = 0,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.status = status
        self.bytesUp = bytesUp
        self.bytesDown = bytesDown
        self.detail = detail
    }
}

public actor ProxyRequestLogStore {
    private var entries: [ProxyRequestLog] = []
    private let maxEntries: Int

    public init(maxEntries: Int = 1000) {
        self.maxEntries = maxEntries
    }

    public func append(_ entry: ProxyRequestLog) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    public func update(id: UUID, status: ProxyRequestStatus? = nil, detail: String? = nil, bytesUp: Int = 0, bytesDown: Int = 0) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let status {
            entries[index].status = status
        }
        if let detail {
            entries[index].detail = detail
        }
        entries[index].bytesUp += bytesUp
        entries[index].bytesDown += bytesDown
    }

    public func recent(limit: Int = 200) -> [ProxyRequestLog] {
        Array(entries.suffix(limit).reversed())
    }
}

public final class LocalHTTPProxyServer: @unchecked Sendable {
    private let config: ProxyConfig
    private let logs: ProxyRequestLogStore
    private let acceptQueue = DispatchQueue(label: "dns-chain.proxy.accept")
    private var listenFD: Int32 = -1
    private var running = false

    public init(config: ProxyConfig, logs: ProxyRequestLogStore) {
        self.config = config
        self.logs = logs
    }

    public func start() throws {
        guard !running else { return }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(config.listenPort).bigEndian
        guard inet_pton(AF_INET, config.listenHost, &address.sin_addr) == 1 else {
            close(fd)
            throw UpstreamError.invalidConfiguration("Invalid proxy listen host \(config.listenHost)")
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        guard listen(fd, 128) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }

        listenFD = fd
        running = true
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if running { continue }
                break
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(clientFD: clientFD)
            }
        }
    }

    private func handle(clientFD: Int32) {
        do {
            let initial = try readInitialRequest(fd: clientFD)
            guard let request = ProxyInitialRequest(headerData: initial.header) else {
                close(clientFD)
                return
            }

            if request.method.uppercased() == "CONNECT" {
                let target = parseHostPort(request.uri, defaultPort: 443)
                try bridge(clientFD: clientFD, request: request, host: target.host, port: target.port, initialPayload: initial.remainder, mode: .tunnel)
            } else if let target = request.forwardTarget() {
                var payload = target.rewrittenHeader
                payload.append(initial.remainder)
                try bridge(clientFD: clientFD, request: request, host: target.host, port: target.port, initialPayload: payload, mode: .forwarding)
            } else {
                close(clientFD)
            }
        } catch {
            close(clientFD)
        }
    }

    private enum BridgeMode {
        case tunnel
        case forwarding
    }

    private func bridge(clientFD: Int32, request: ProxyInitialRequest, host: String, port: Int, initialPayload: Data, mode: BridgeMode) throws {
        let id = UUID()
        Task {
            await logs.append(ProxyRequestLog(id: id, method: request.method, targetHost: host, targetPort: port, status: .connecting))
        }

        do {
            let remoteFD = try connectToHost(host, port: port)
            switch mode {
            case .tunnel:
                try sendAll(fd: clientFD, data: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
                if !initialPayload.isEmpty {
                    try sendAll(fd: remoteFD, data: initialPayload)
                    Task { await logs.update(id: id, bytesUp: initialPayload.count) }
                }
                Task { await logs.update(id: id, status: .tunnel) }
            case .forwarding:
                try sendAll(fd: remoteFD, data: initialPayload)
                Task { await logs.update(id: id, status: .forwarding, bytesUp: initialPayload.count) }
            }

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.pump(sourceFD: clientFD, destinationFD: remoteFD, id: id, direction: .up)
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.pump(sourceFD: remoteFD, destinationFD: clientFD, id: id, direction: .down)
                group.leave()
            }
            group.wait()
            close(clientFD)
            close(remoteFD)
            Task { await logs.update(id: id, status: .closed) }
        } catch {
            close(clientFD)
            Task { await logs.update(id: id, status: .failed, detail: String(describing: error)) }
        }
    }

    private enum PumpDirection {
        case up
        case down
    }

    private func pump(sourceFD: Int32, destinationFD: Int32, id: UUID, direction: PumpDirection) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = recv(sourceFD, &buffer, buffer.count, 0)
            if count <= 0 {
                shutdown(destinationFD, SHUT_WR)
                return
            }
            let data = Data(buffer.prefix(count))
            do {
                try sendAll(fd: destinationFD, data: data)
                Task {
                    switch direction {
                    case .up:
                        await logs.update(id: id, bytesUp: count)
                    case .down:
                        await logs.update(id: id, bytesDown: count)
                    }
                }
            } catch {
                shutdown(destinationFD, SHUT_RDWR)
                return
            }
        }
    }
}

private struct InitialProxyBytes {
    var header: Data
    var remainder: Data
}

private func readInitialRequest(fd: Int32) throws -> InitialProxyBytes {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = recv(fd, &chunk, chunk.count, 0)
        guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .ECONNRESET) }
        buffer.append(chunk, count: count)
        if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
            return InitialProxyBytes(header: Data(buffer[..<range.upperBound]), remainder: Data(buffer[range.upperBound...]))
        }
        if buffer.count > 1024 * 1024 {
            throw UpstreamError.invalidResponse
        }
    }
}

private func connectToHost(_ host: String, port: Int) throws -> Int32 {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var result: UnsafeMutablePointer<addrinfo>?
    let code = getaddrinfo(host, String(port), &hints, &result)
    guard code == 0, let result else {
        throw UpstreamError.network(String(cString: gai_strerror(code)))
    }
    defer { freeaddrinfo(result) }

    var cursor: UnsafeMutablePointer<addrinfo>? = result
    var lastErrno = ECONNREFUSED
    while let item = cursor {
        let fd = socket(item.pointee.ai_family, item.pointee.ai_socktype, item.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, item.pointee.ai_addr, item.pointee.ai_addrlen) == 0 {
                return fd
            }
            lastErrno = errno
            close(fd)
        }
        cursor = item.pointee.ai_next
    }
    throw POSIXError(.init(rawValue: lastErrno) ?? .ECONNREFUSED)
}

private func sendAll(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var sent = 0
        while sent < rawBuffer.count {
            let count = send(fd, base.advanced(by: sent), rawBuffer.count - sent, 0)
            guard count > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EPIPE)
            }
            sent += count
        }
    }
}

private struct ProxyForwardTarget {
    var host: String
    var port: Int
    var rewrittenHeader: Data
}

private struct ProxyInitialRequest {
    var method: String
    var uri: String
    var version: String
    var headerLines: [String]

    init?(headerData: Data) {
        let header = String(decoding: headerData, as: UTF8.self)
        let normalized = header.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }
        method = parts[0]
        uri = parts[1]
        version = parts[2]
        headerLines = Array(lines.dropLast().filter { !$0.isEmpty })
    }

    func forwardTarget() -> ProxyForwardTarget? {
        let hostHeader = headerLines.first { $0.lowercased().hasPrefix("host:") }
            .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }

        let url = URL(string: uri)
        let parsedHostHeader = hostHeader.map { parseHostPort($0, defaultPort: 80) }
        let host = url?.host ?? parsedHostHeader?.host
        let port = url?.port ?? parsedHostHeader?.port ?? (url?.scheme == "https" ? 443 : 80)
        guard let host, !host.isEmpty else { return nil }

        let path: String
        if let url, url.scheme != nil {
            var value = url.path.isEmpty ? "/" : url.path
            if let query = url.query {
                value += "?\(query)"
            }
            path = value
        } else {
            path = uri
        }

        var rewritten = headerLines
        rewritten[0] = "\(method) \(path) \(version)"
        rewritten = rewritten.filter { !$0.lowercased().hasPrefix("proxy-connection:") }
        var header = rewritten.joined(separator: "\r\n")
        header += "\r\n\r\n"
        return ProxyForwardTarget(host: host, port: port, rewrittenHeader: Data(header.utf8))
    }
}

private func parseHostPort(_ value: String, defaultPort: Int) -> (host: String, port: Int) {
    if value.hasPrefix("["),
       let end = value.firstIndex(of: "]") {
        let host = String(value[value.index(after: value.startIndex)..<end])
        let rest = value[value.index(after: end)...]
        if rest.hasPrefix(":"),
           let port = Int(rest.dropFirst()) {
            return (host, port)
        }
        return (host, defaultPort)
    }

    let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
    if parts.count == 2, let port = Int(parts[1]) {
        return (parts[0], port)
    }
    return (value, defaultPort)
}
