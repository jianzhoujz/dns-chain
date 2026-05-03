import Testing
import Foundation
@testable import DNSChainCore

@Test
func parsesDNSQuestion() throws {
    let query = Data.makeQuery(id: 0xbeef, name: "Example.COM", type: 1)
    let message = try DNSMessage.parse(query)
    #expect(message.id == 0xbeef)
    #expect(message.question.normalizedName == "example.com")
    #expect(message.question.type == 1)
}

@Test
func matchesIPv4CIDR() throws {
    let cidr = try #require(IPAddressCIDR("10.20.30.0/24"))
    #expect(cidr.contains("10.20.30.40"))
    #expect(!cidr.contains("10.20.31.40"))
}

@Test
func parsesScutilDNSResolvers() throws {
    let output = """
    DNS configuration

    resolver #1
      nameserver[0] : 192.168.1.1
      if_index : 14 (en0)

    resolver #2
      domain   : corp
      nameserver[0] : 10.0.0.53
      port     : 53
    """
    let resolvers = SystemDNSParser.parseScutilDNS(output)
    #expect(resolvers.count == 2)
    #expect(SystemDNSParser.bestResolver(for: "service.corp", resolvers: resolvers)?.nameservers == ["10.0.0.53"])
    #expect(SystemDNSParser.bestResolver(for: "example.com", resolvers: resolvers)?.nameservers == ["192.168.1.1"])
}
