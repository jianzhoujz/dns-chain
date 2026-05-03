import Foundation
import Darwin

public struct PlainDNSUpstream: DNSUpstream {
    public let id: String
    public let name: String
    public let type: UpstreamType = .plainDNS
    public let servers: [String]
    public let port: Int
    public let timeoutMs: Int

    public init(id: String, name: String, servers: [String], port: Int = 53, timeoutMs: Int = 1500) {
        self.id = id
        self.name = name
        self.servers = servers
        self.port = port
        self.timeoutMs = timeoutMs
    }

    public func query(_ request: Data) async throws -> UpstreamResponse {
        var lastError: Error = UpstreamError.network("No DNS server attempted")
        for server in servers {
            do {
                let (data, latency) = try await measureLatency {
                    let udpResponse = try await sendUDP(request, host: server)
                    if let parsed = try? DNSMessage.parse(udpResponse), parsed.flags & 0x0200 == 0 {
                        return udpResponse
                    }
                    return try await sendTCP(request, host: server)
                }
                let message = try DNSMessage.parse(data)
                return UpstreamResponse(
                    message: message,
                    attempt: AttemptLog(upstreamID: id, upstreamName: name, status: .success, latencyMs: latency, detail: server)
                )
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func sendUDP(_ request: Data, host: String) async throws -> Data {
        try await withTimeout(milliseconds: timeoutMs) {
            try await Task.detached {
                try sendBlockingUDP(request, host: host, port: port, timeoutMs: timeoutMs)
            }.value
        }
    }

    private func sendTCP(_ request: Data, host: String) async throws -> Data {
        try await withTimeout(milliseconds: timeoutMs) {
            try await Task.detached {
                try sendBlockingTCP(request, host: host, port: port, timeoutMs: timeoutMs)
            }.value
        }
    }
}

private func sendBlockingUDP(_ request: Data, host: String, port: Int, timeoutMs: Int) throws -> Data {
    let resolved = try resolveAddress(host: host, port: port, socktype: SOCK_DGRAM)
    let fd = socket(resolved.family, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { throw UpstreamError.network(String(cString: strerror(errno))) }
    defer { close(fd) }
    setTimeout(fd, timeoutMs: timeoutMs)

    let sent = resolved.withSockaddr { address, length in
        request.withUnsafeBytes { buffer in
            sendto(fd, buffer.baseAddress, buffer.count, 0, address, length)
        }
    }
    guard sent == request.count else {
        throw errno == EAGAIN ? UpstreamError.timeout : UpstreamError.network(String(cString: strerror(errno)))
    }

    var response = [UInt8](repeating: 0, count: 4096)
    let count = recv(fd, &response, response.count, 0)
    guard count > 0 else {
        throw errno == EAGAIN ? UpstreamError.timeout : UpstreamError.network(String(cString: strerror(errno)))
    }
    return Data(response.prefix(count))
}

private func sendBlockingTCP(_ request: Data, host: String, port: Int, timeoutMs: Int) throws -> Data {
    let resolved = try resolveAddress(host: host, port: port, socktype: SOCK_STREAM)
    let fd = socket(resolved.family, SOCK_STREAM, IPPROTO_TCP)
    guard fd >= 0 else { throw UpstreamError.network(String(cString: strerror(errno))) }
    defer { close(fd) }
    setTimeout(fd, timeoutMs: timeoutMs)

    let connectResult = resolved.withSockaddr { address, length in
        connect(fd, address, length)
    }
    guard connectResult == 0 else {
        throw errno == EAGAIN ? UpstreamError.timeout : UpstreamError.network(String(cString: strerror(errno)))
    }

    var payload = Data()
    payload.appendUInt16(UInt16(request.count))
    payload.append(request)
    try payload.withUnsafeBytes { buffer in
        guard send(fd, buffer.baseAddress, buffer.count, 0) == buffer.count else {
            throw UpstreamError.network(String(cString: strerror(errno)))
        }
    }

    let lengthData = try recvExact(fd: fd, count: 2)
    let length = Int(UInt16(lengthData[0]) << 8 | UInt16(lengthData[1]))
    return try recvExact(fd: fd, count: length)
}

private func recvExact(fd: Int32, count: Int) throws -> Data {
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: count)
    while output.count < count {
        let read = recv(fd, &buffer, count - output.count, 0)
        guard read > 0 else {
            throw errno == EAGAIN ? UpstreamError.timeout : UpstreamError.network(String(cString: strerror(errno)))
        }
        output.append(buffer, count: read)
    }
    return output
}

private struct ResolvedAddress {
    var storage: sockaddr_storage
    var length: socklen_t
    var family: Int32

    func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) rethrows -> T {
        var copy = storage
        return try withUnsafePointer(to: &copy) {
            try body(UnsafeRawPointer($0).assumingMemoryBound(to: sockaddr.self), length)
        }
    }
}

private func resolveAddress(host: String, port: Int, socktype: Int32) throws -> ResolvedAddress {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: socktype,
        ai_protocol: 0,
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

    var storage = sockaddr_storage()
    memcpy(&storage, result.pointee.ai_addr, Int(result.pointee.ai_addrlen))
    return ResolvedAddress(storage: storage, length: result.pointee.ai_addrlen, family: result.pointee.ai_family)
}

private func setTimeout(_ fd: Int32, timeoutMs: Int) {
    var timeout = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
}

public func withTimeout<T: Sendable>(milliseconds: Int, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            throw UpstreamError.timeout
        }
        guard let value = try await group.next() else {
            throw UpstreamError.timeout
        }
        group.cancelAll()
        return value
    }
}
