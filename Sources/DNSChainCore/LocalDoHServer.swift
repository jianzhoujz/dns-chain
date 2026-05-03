import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
@preconcurrency import NIOSSL
import NIOFoundationCompat

public final class LocalDoHServer: @unchecked Sendable {
    private let resolver: ChainResolver
    private let config: ServerConfig
    private let certificatePaths: CertificatePaths
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init(resolver: ChainResolver, config: ServerConfig, certificatePaths: CertificatePaths = .default()) {
        self.resolver = resolver
        self.config = config
        self.certificatePaths = certificatePaths
    }

    public func start() throws {
        guard channel == nil else { return }
        let certs = try NIOSSLCertificate.fromPEMFile(certificatePaths.serverCertificate.path).map { NIOSSLCertificateSource.certificate($0) }
        let privateKey = try NIOSSLPrivateKey(file: certificatePaths.serverKey.path, format: .pem)
        let tlsConfiguration = TLSConfiguration.makeServerConfiguration(certificateChain: certs, privateKey: .privateKey(privateKey))
        let sslContext = try NIOSSLContext(configuration: tlsConfiguration)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        let resolver = self.resolver
        let path = self.config.dohPath

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 128)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                do {
                    let sslHandler = NIOSSLServerHandler(context: sslContext)
                    try channel.pipeline.syncOperations.addHandler(sslHandler)
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
                return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(DNSChainDoHHandler(resolver: resolver, path: path))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        self.channel = try bootstrap.bind(host: config.listenHost, port: config.listenPort).wait()
        self.group = group
    }

    public func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group?.syncShutdownGracefully()
        group = nil
    }
}

final class DNSChainDoHHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let resolver: ChainResolver
    private let path: String
    private var requestHead: HTTPRequestHead?
    private var body = ByteBufferAllocator().buffer(capacity: 512)

    init(resolver: ChainResolver, path: String) {
        self.resolver = resolver
        self.path = path
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let head = requestHead else {
                writeError(context: context, status: .badRequest)
                return
            }
            let requestData: Data?
            if head.method == .POST {
                requestData = validatePost(head) ? body.readData(length: body.readableBytes) : nil
            } else if head.method == .GET {
                requestData = decodeGET(head.uri)
            } else {
                requestData = nil
            }
            guard let requestData else {
                writeError(context: context, status: .badRequest)
                return
            }

            let keepAlive = head.isKeepAlive
            let resolver = self.resolver
            let promise = context.eventLoop.makePromise(of: DoHHandlerResult.self)
            promise.futureResult.whenSuccess { result in
                switch result {
                case .response(let response):
                    self.writeDNSResponse(context: context, data: response, keepAlive: keepAlive)
                case .error(let status):
                    self.writeError(context: context, status: status, keepAlive: keepAlive)
                }
            }
            Task {
                do {
                    let response = try await resolver.resolve(requestData)
                    promise.succeed(.response(response))
                } catch ResolveError.invalidRequest {
                    promise.succeed(.error(.badRequest))
                } catch {
                    promise.succeed(.error(.internalServerError))
                }
            }
        }
    }

    private func validatePost(_ head: HTTPRequestHead) -> Bool {
        guard pathFromURI(head.uri) == path else { return false }
        let contentTypes = head.headers["content-type"].map { $0.lowercased() }
        return contentTypes.contains { $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) == "application/dns-message" }
    }

    private func decodeGET(_ uri: String) -> Data? {
        guard pathFromURI(uri) == path,
              let components = URLComponents(string: "https://localhost\(uri)"),
              let dns = components.queryItems?.first(where: { $0.name == "dns" })?.value else {
            return nil
        }
        return Data(base64URLEncoded: dns)
    }

    private func pathFromURI(_ uri: String) -> String? {
        URLComponents(string: "https://localhost\(uri)")?.path
    }

    private func writeDNSResponse(context: ChannelHandlerContext, data: Data, keepAlive: Bool) {
        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: "application/dns-message")
        headers.add(name: "content-length", value: "\(data.count)")
        if keepAlive {
            headers.add(name: "connection", value: "keep-alive")
        }
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive {
                context.close(promise: nil)
            }
        }
    }

    private func writeError(context: ChannelHandlerContext, status: HTTPResponseStatus, keepAlive: Bool = false) {
        var headers = HTTPHeaders()
        headers.add(name: "content-length", value: "0")
        if keepAlive {
            headers.add(name: "connection", value: "keep-alive")
        }
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive {
                context.close(promise: nil)
            }
        }
    }
}

private enum DoHHandlerResult {
    case response(Data)
    case error(HTTPResponseStatus)
}

extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }
}
