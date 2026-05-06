import Testing
import Foundation
@testable import DNSChainCore

@Test
func decodesConfigWithoutLaunchAtLogin() throws {
    let json = """
    {
      "server": {
        "listen_host": "127.0.0.1",
        "listen_port": 8053,
        "doh_path": "/dns-query"
      },
      "dns_chain": [],
      "fallback_when": {
        "timeout": true,
        "network_error": true,
        "servfail": true,
        "refused": true,
        "empty_answer": true,
        "blocked_ip": true,
        "blocked_cname": true,
        "nxdomain": false
      },
      "blocked_answers": {
        "ip_cidrs": [],
        "cname_suffixes": []
      },
      "protected_suffixes": [],
      "cache": {
        "enabled": true,
        "max_ttl_seconds": 300,
        "min_ttl_seconds": 5,
        "negative_ttl_seconds": 30
      },
      "logging": {
        "enabled": true,
        "max_entries": 1000
      },
      "launch_at_login": true
    }
    """
    let config = try JSONDecoder().decode(DNSChainConfig.self, from: Data(json.utf8))
    #expect(config.server.listenHost == "127.0.0.1")
    #expect(config.fallbackWhen.invalidResponse == true)
}

@Test
func defaultConfigKeepsEmptyAnswerFallbackOffAndBlockedCNAMEsEmpty() {
    let config = DNSChainConfig()

    #expect(config.fallbackWhen.emptyAnswer == false)
    #expect(config.fallbackWhen.invalidResponse == true)
    #expect(config.blockedAnswers.cnameSuffixes.isEmpty)
}
