import XCTest
@testable import NodensCore

final class ProfileTests: XCTestCase {
    private let id = UUID(uuidString: "3F2A0000-0000-0000-0000-000000000000")!

    func testSlug() {
        XCTAssertEqual(VPNProfile.slug(name: "Work", id: id), "work-3f2a")
        XCTAssertEqual(VPNProfile.slug(name: "Uni — Café VPN!", id: id), "uni-caf-vp-3f2a")
        XCTAssertEqual(VPNProfile.slug(name: "***", id: id), "vpn-3f2a")
        for name in ["A very long profile name indeed", "x", "ends with dash -"] {
            let slug = VPNProfile.slug(name: name, id: id)
            XCTAssertLessThanOrEqual(slug.count, 15)
            XCTAssertNil(slug.range(of: "[^a-z0-9-]", options: .regularExpression), slug)
            XCTAssertFalse(slug.contains("--"), slug)
        }
    }

    /// wg-quick: ^[a-zA-Z0-9_=+.-]{1,15}$
    func testSlugIsAValidWireGuardInterfaceName() {
        let slug = VPNProfile.slug(name: "Office VPN in the cloud", id: UUID())
        XCTAssertNotNil(slug.range(of: "^[a-zA-Z0-9_=+.-]{1,15}$", options: .regularExpression), slug)
    }

    func testRoundTrip() throws {
        let profile = VPNProfile(id: id, name: "Work", kind: .wireguard, config: "[Interface]\n", username: "alice@example.edu")
        let decoded = try JSONDecoder().decode(VPNProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }
}

final class TunnelStateTests: XCTestCase {
    /// Management states as openvpn reports them during a connect.
    func testClassify() {
        XCTAssertEqual(TunnelState.classify("EXITING"), .disconnected)
        XCTAssertEqual(TunnelState.classify(""), .disconnected)
        XCTAssertEqual(TunnelState.classify("connected"), .connected)
        for state in ["RESOLVE", "WAIT", "AUTH", "GET_CONFIG", "ASSIGN_IP", "ADD_ROUTES", "RECONNECTING", "UNKNOWN"] {
            XCTAssertEqual(TunnelState.classify(state), .connecting(state))
        }
    }

    func testAppleScriptQuoting() {
        XCTAssertEqual(AppleScript.quote(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertTrue(AppleScript.isUserCancelled("execution error: User canceled. (-128)"))
        XCTAssertFalse(AppleScript.isUserCancelled("execution error: other (-1712)"))
    }
}

final class StatusGlyphTests: XCTestCase {
    func testTailnetState() {
        XCTAssertEqual(StatusGlyph.tailnetState(backend: "Running", changing: false), .on)
        XCTAssertEqual(StatusGlyph.tailnetState(backend: "Starting", changing: false), .transition)
        XCTAssertEqual(StatusGlyph.tailnetState(backend: "Stopped", changing: false), .off)
        XCTAssertEqual(StatusGlyph.tailnetState(backend: "NeedsLogin", changing: false), .off)
        XCTAssertEqual(StatusGlyph.tailnetState(backend: nil, changing: false), .off)
        XCTAssertEqual(StatusGlyph.tailnetState(backend: "Running", changing: true), .transition)
    }

    func testVPNState() {
        let idle = TunnelConfig(name: "Home", rawState: "EXITING")
        let up = TunnelConfig(name: "Work", rawState: "CONNECTED")
        let auth = TunnelConfig(name: "Work", rawState: "AUTH")
        XCTAssertEqual(StatusGlyph.vpnState(tunnels: [], changing: false), .off)
        XCTAssertEqual(StatusGlyph.vpnState(tunnels: [idle], changing: false), .off)
        XCTAssertEqual(StatusGlyph.vpnState(tunnels: [idle, auth], changing: false), .transition)
        XCTAssertEqual(StatusGlyph.vpnState(tunnels: [idle, up], changing: false), .on)
        // A disconnect in flight shows as changing, even while the tunnel still reads CONNECTED.
        XCTAssertEqual(StatusGlyph.vpnState(tunnels: [up], changing: true), .transition)
    }

    func testDescription() {
        XCTAssertEqual(StatusGlyph.describe(GlyphSpec(tailnet: .on, vpn: .off)), "Tailscale on, VPN off")
        XCTAssertEqual(
            StatusGlyph.describe(GlyphSpec(tailnet: .on, vpn: .transition, attention: true)),
            "Tailscale on, VPN changing, needs attention"
        )
    }
}
