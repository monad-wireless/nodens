import XCTest
@testable import NodensCore

final class AdminScriptTests: XCTestCase {
    private let hookSource = "/Applications/Nodens.app/Contents/Resources/nodens-hook"

    private func setup(hosts: String? = "/tmp/st/hosts", entries: String? = nil) -> RootSetup {
        RootSetup(slug: "work-3f2a", hookSource: hookSource, stagedHosts: hosts, stagedTailnetEntries: entries)
    }

    private func openvpnLaunch(hosts: String? = "/tmp/st/hosts", entries: String? = nil) -> OpenVPNLaunch {
        OpenVPNLaunch(
            setup: setup(hosts: hosts, entries: entries),
            openvpn: "/opt/homebrew/sbin/openvpn",
            stagedConfig: "/var/folders/x/T/nodens-1/config.ovpn",
            managementPort: 50123,
            managementPasswordFile: "/Users/me/Library/Application Support/Nodens/run/work-3f2a.pw",
            routeStrategy: .hostRoutes
        )
    }

    func testOurOpenVPNOptionsFollowTheConfig() {
        let arguments = AdminScript.openvpnArguments(openvpnLaunch())
        XCTAssertEqual(Array(arguments.prefix(2)), ["--config", "/usr/local/etc/nodens/work-3f2a.ovpn"])
        for option in ["--management-hold", "--management-query-passwords", "--route-up", "--route-pre-down", "--dns-updown", "--daemon"] {
            XCTAssertTrue(arguments.contains(option), option)
        }
        let management = arguments.firstIndex(of: "--management")!
        XCTAssertEqual(Array(arguments[management...].prefix(4)),
                       ["--management", "127.0.0.1", "50123", "/Users/me/Library/Application Support/Nodens/run/work-3f2a.pw"])
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--route-up")! + 1], "/usr/local/libexec/nodens/hook ovpn-up")
    }

    func testRootPathsHaveNoSpaces() {
        // openvpn splits its script commands on spaces.
        for path in [HookPaths.hook, HookPaths.config("a-1"), HookPaths.wgConfig("a-1"), HookPaths.state, HookPaths.etc] {
            XCTAssertFalse(path.contains(" "), path)
        }
    }

    func testOpenVPNConnectCommand() {
        let command = AdminScript.openvpnConnect(openvpnLaunch(entries: "/tmp/st/tailnet.entries"))
        XCTAssertTrue(command.hasPrefix("umask 022 && "))
        XCTAssertTrue(command.contains("'\(hookSource)' /usr/local/libexec/nodens/hook"))
        XCTAssertTrue(command.contains("hook resolver-apply tailnet '/tmp/st/tailnet.entries'"))
        XCTAssertTrue(command.contains("/usr/local/etc/nodens/work-3f2a.hosts"))
        // stdin, stdout and stderr all redirected, or `do shell script` waits for the daemon.
        XCTAssertTrue(command.hasSuffix("</dev/null >/Library/Logs/Nodens/work-3f2a.launch.log 2>&1"))
        // Cleanup runs before the new tunnel's files are installed.
        XCTAssertLessThan(command.range(of: "cleanup-stale")!.lowerBound, command.range(of: "work-3f2a.ovpn")!.lowerBound)
    }

    func testNoHostsRemovesOldHostsFile() {
        XCTAssertTrue(AdminScript.openvpnConnect(openvpnLaunch(hosts: nil)).contains("/bin/rm -f /usr/local/etc/nodens/work-3f2a.hosts"))
    }

    func testWireGuardCommands() {
        let launch = WireGuardLaunch(
            setup: setup(hosts: nil),
            wgQuick: "/opt/homebrew/bin/wg-quick",
            stagedConfig: "/var/folders/x/T/nodens-1/work-3f2a.conf"
        )
        let up = AdminScript.wireguardUp(launch)
        XCTAssertTrue(up.contains("/usr/bin/install -m 0600 -o root -g wheel '/var/folders/x/T/nodens-1/work-3f2a.conf' /usr/local/etc/nodens/wg/work-3f2a.conf"))
        XCTAssertTrue(up.hasSuffix("/usr/bin/env PATH=\(AdminScript.toolPath) '/opt/homebrew/bin/wg-quick' up /usr/local/etc/nodens/wg/work-3f2a.conf </dev/null >>/Library/Logs/Nodens/work-3f2a.log 2>&1"))
        XCTAssertLessThan(up.range(of: "cleanup-stale")!.lowerBound, up.range(of: " up ")!.lowerBound)
        XCTAssertTrue(up.contains("/bin/chmod 0700 /usr/local/etc/nodens /usr/local/etc/nodens/wg"))

        let down = AdminScript.wireguardDown(wgQuick: "/opt/homebrew/bin/wg-quick", slug: "work-3f2a", hookSource: hookSource)
        XCTAssertTrue(down.contains("down /usr/local/etc/nodens/wg/work-3f2a.conf"))
        XCTAssertTrue(down.contains("|| true; }"))
        XCTAssertTrue(down.hasSuffix("/usr/local/libexec/nodens/hook cleanup-stale"))
    }

    func testShellQuote() {
        XCTAssertEqual(AdminScript.quote("it's"), #"'it'\''s'"#)
    }
}
