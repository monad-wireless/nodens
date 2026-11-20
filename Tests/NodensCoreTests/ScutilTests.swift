import XCTest
@testable import NodensCore

final class ScutilTests: XCTestCase {
    /// `scutil --dns` with Tailscale DNS on.
    private let tailscaleDefault = """
    DNS configuration

    resolver #1
      search domain[0] : corp.internal
      nameserver[0] : 100.100.100.100
      nameserver[1] : fd7a:115c:a1e0::53
      if_index : 39 (utun13)
      flags    : Supplemental, Request A records, Request AAAA records
      order    : 101600

    resolver #2
      nameserver[0] : 2001:db8::1
      nameserver[1] : 192.168.1.1
      if_index : 14 (en0)

    DNS configuration (for scoped queries)

    resolver #1
      nameserver[0] : 192.168.1.1
    """

    /// The same Mac two seconds after `tailscale set --accept-dns=false`.
    private let routerDefault = """
    DNS configuration

    resolver #1
      nameserver[0] : 2001:db8::1
      nameserver[1] : 192.168.1.1
      if_index : 14 (en0)

    resolver #2
      domain   : local
      options  : mdns

    DNS configuration (for scoped queries)

    resolver #2
      nameserver[0] : 100.100.100.100
    """

    func testTailscaleHoldsTheDefaultResolver() {
        XCTAssertEqual(Scutil.defaultResolverNameservers(tailscaleDefault), ["100.100.100.100", "fd7a:115c:a1e0::53"])
        XCTAssertTrue(Scutil.tailscaleHoldsDefault(tailscaleDefault))
    }

    func testRouterHoldsTheDefaultResolver() {
        XCTAssertEqual(Scutil.defaultResolverNameservers(routerDefault), ["2001:db8::1", "192.168.1.1"])
        XCTAssertFalse(Scutil.tailscaleHoldsDefault(routerDefault))
    }

    func testEmptyOutput() {
        XCTAssertEqual(Scutil.defaultResolverNameservers(""), [])
    }
}
