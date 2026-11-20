import XCTest
@testable import NodensCore

final class TailscaleParsingTests: XCTestCase {
    /// Shape of `tailscale status --json --peers=false` on Tailscale 1.102.
    func testStatusOfARunningNode() throws {
        let json = """
        {
          "BackendState": "Running",
          "TailscaleIPs": ["100.64.0.3", "fd7a:115c:a1e0::3"],
          "Self": { "DNSName": "laptop.corp.internal.", "HostName": "LAPTOP" },
          "MagicDNSSuffix": "corp.internal",
          "CurrentTailnet": {
            "Name": "headscale.example.org",
            "MagicDNSSuffix": "corp.internal",
            "MagicDNSEnabled": true
          },
          "ExtraRecords": [
            { "Name": "db.services.corp.internal", "Type": "A", "Value": "172.16.1.1" }
          ],
          "Peer": null
        }
        """
        let status = try XCTUnwrap(TailscaleParsing.parseStatus(json))
        XCTAssertTrue(status.isRunning)
        XCTAssertEqual(status.tailscaleIPs, ["100.64.0.3", "fd7a:115c:a1e0::3"])
        XCTAssertEqual(status.magicDNSSuffix, "corp.internal")
        XCTAssertEqual(status.tailnetName, "headscale.example.org")
        XCTAssertEqual(status.selfDNSName, "laptop.corp.internal")
        XCTAssertEqual(status.extraRecordNames, ["db.services.corp.internal"])
    }

    func testStatusOfAStoppedNode() throws {
        let status = try XCTUnwrap(TailscaleParsing.parseStatus(#"{"BackendState": "Stopped"}"#))
        XCTAssertFalse(status.isRunning)
        XCTAssertEqual(status.magicDNSSuffix, "")
        XCTAssertNil(status.selfDNSName)
        XCTAssertEqual(status.extraRecordNames, [])
    }

    func testStatusRejectsNonJSON() {
        XCTAssertNil(TailscaleParsing.parseStatus("Tailscale is stopped."))
    }

    /// Output of `tailscale switch --list` on Tailscale 1.102.
    func testSwitchList() {
        let text = """
        ID    Tailnet                Account
        1a2b  team.example.org       bob
        3c4d  headscale.example.org  alice*

        """
        XCTAssertEqual(TailscaleParsing.parseSwitchList(text), [
            TailscaleProfile(id: "1a2b", tailnet: "team.example.org", account: "bob", isCurrent: false),
            TailscaleProfile(id: "3c4d", tailnet: "headscale.example.org", account: "alice", isCurrent: true),
        ])
    }

    func testCorpDNS() {
        XCTAssertEqual(TailscaleParsing.parseCorpDNS(prefsJSON: #"{"ControlURL": "x", "CorpDNS": true}"#), true)
        XCTAssertEqual(TailscaleParsing.parseCorpDNS(prefsJSON: #"{"CorpDNS": false}"#), false)
        XCTAssertNil(TailscaleParsing.parseCorpDNS(prefsJSON: #"{"RouteAll": true}"#))
        XCTAssertNil(TailscaleParsing.parseCorpDNS(prefsJSON: "not json"))
    }

    /// Excerpt of `tailscale dns status` on Tailscale 1.102.
    func testSplitRoutes() {
        let text = """
        === MagicDNS configuration ===

        Resolvers (in preference order):
          (no resolvers configured, system default will be used: see 'System DNS configuration' below)

        Split DNS Routes:
          - k8s.internal                   -> 10.43.0.10

        Search Domains:
          - corp.internal
          - k8s.internal
        """
        XCTAssertEqual(
            TailscaleParsing.parseSplitRoutes(dnsStatus: text),
            [SplitRoute(domain: "k8s.internal", resolvers: ["10.43.0.10"])]
        )
    }

    func testSplitRoutesWithSeveralResolversAndTrailingDot() {
        let text = """
        Split DNS Routes:
          - corp.example.internal.  -> 10.0.0.53, 10.0.1.53

        """
        XCTAssertEqual(
            TailscaleParsing.parseSplitRoutes(dnsStatus: text),
            [SplitRoute(domain: "corp.example.internal", resolvers: ["10.0.0.53", "10.0.1.53"])]
        )
    }

    func testNoSplitRoutes() {
        XCTAssertEqual(TailscaleParsing.parseSplitRoutes(dnsStatus: "Search Domains:\n  - corp.internal\n"), [])
    }

    /// Shapes of `tailscale debug prefs` and `tailscale debug derp-map` on 1.102.
    func testTailnetInfrastructure() {
        XCTAssertEqual(TailscaleParsing.controlHost(prefsJSON: #"{"ControlURL": "https://headscale.example.org", "CorpDNS": false}"#), "headscale.example.org")
        XCTAssertNil(TailscaleParsing.controlHost(prefsJSON: #"{"CorpDNS": true}"#))
        let derp = """
        {"Regions": {"999": {"RegionID": 999, "RegionCode": "lab",
          "Nodes": [{"Name": "999", "RegionID": 999, "HostName": "derp.example.org", "STUNPort": 3478, "DERPPort": 443}]},
         "1": {"Nodes": [{"HostName": "derp1.example.net", "IPv4": "203.0.113.7"}]}}}
        """
        XCTAssertEqual(TailscaleParsing.relayHosts(derpMapJSON: derp), ["203.0.113.7", "derp.example.org"])
        XCTAssertEqual(TailscaleParsing.relayHosts(derpMapJSON: "nope"), [])
    }
}
