import Testing
@testable import DNSChainCore
import NIOEmbedded
import NIOHTTP1

@Test
func handlerRejectsWrongPath() throws {
    let channel = EmbeddedChannel()
    try channel.pipeline.addHandler(DNSChainDoHHandler(resolver: ChainResolver(config: DNSChainConfig()), path: "/dns-query")).wait()

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/wrong")
    head.headers.add(name: "content-type", value: "application/dns-message")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    guard case .head(let responseHead) = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
        Issue.record("expected response head")
        return
    }
    #expect(responseHead.status == .badRequest)
}

@Test
func handlerRejectsWrongContentType() throws {
    let channel = EmbeddedChannel()
    try channel.pipeline.addHandler(DNSChainDoHHandler(resolver: ChainResolver(config: DNSChainConfig()), path: "/dns-query")).wait()

    var head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "/dns-query")
    head.headers.add(name: "content-type", value: "application/json")
    try channel.writeInbound(HTTPServerRequestPart.head(head))
    try channel.writeInbound(HTTPServerRequestPart.end(nil))

    guard case .head(let responseHead) = try channel.readOutbound(as: HTTPServerResponsePart.self) else {
        Issue.record("expected response head")
        return
    }
    #expect(responseHead.status == .badRequest)
}
