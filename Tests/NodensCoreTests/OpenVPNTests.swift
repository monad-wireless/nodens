import XCTest
@testable import NodensCore

final class OpenVPNConfigTests: XCTestCase {
    /// A typical university-style client file (keys replaced).
    private let client = """
    client
    dev tun
    proto udp
    remote vpn.example.edu
    port 1194
    persist-tun
    auth-user-pass
    auth-nocache
    verb 3
    <ca>
    -----BEGIN CERTIFICATE-----
    up /tmp/not-a-directive-inside-a-block
    -----END CERTIFICATE-----
    </ca>
    key-direction 1
    <tls-auth>
    -----BEGIN OpenVPN Static key V1-----
    00
    -----END OpenVPN Static key V1-----
    </tls-auth>
    """

    func testClientIsUsableAndUntouched() {
        let report = OpenVPNConfig.check(client)
        XCTAssertTrue(report.isUsable, "\(report.problems)")
        XCTAssertTrue(report.needsCredentials)
        XCTAssertEqual(report.remotes, ["vpn.example.edu"])
        XCTAssertEqual(report.removed, [])
        // Text inside an inline block is material, never a directive.
        XCTAssertTrue(report.sanitized.contains("up /tmp/not-a-directive-inside-a-block"))
    }

    func testDangerousDirectivesAreRemoved() {
        let text = """
        remote 192.0.2.4 443
        script-security 3
        up /bin/evil
        --route-up "/bin/evil arg"
        plugin /lib/x.so
        management 0.0.0.0 7505
        daemon
        log /etc/passwd
        user root
        setenv NODENS_SLUG other
        config /etc/other.conf
        auth-user-pass /Users/me/creds.txt
        redirect-gateway def1
        """
        let report = OpenVPNConfig.check(text)
        XCTAssertTrue(report.isUsable)
        XCTAssertEqual(
            report.removed,
            ["script-security", "up", "route-up", "plugin", "management", "daemon", "log", "user", "setenv", "config", "auth-user-pass file"]
        )
        XCTAssertEqual(report.remotes, ["192.0.2.4 443"])
        XCTAssertTrue(report.sanitized.contains("\nauth-user-pass\n"))
        XCTAssertTrue(report.sanitized.contains("redirect-gateway def1"))
        XCTAssertFalse(report.sanitized.contains("/bin/evil"))
        XCTAssertFalse(report.sanitized.contains("creds.txt"))
    }

    func testCodeLoadingDirectivesAreRemoved() {
        let report = OpenVPNConfig.check("remote a.example\nproviders legacy\nengine dynamic\npkcs11-providers /lib/p.so\nreplay-persist /etc/x\ntls-export-cert /etc\n")
        XCTAssertEqual(report.removed, ["providers", "engine", "pkcs11-providers", "replay-persist", "tls-export-cert"])
    }

    /// openvpn's tokenizer would read each of these as `up /bin/x`.
    func testDisguisedDirectivesFailClosed() {
        let disguised = [
            "\"up\" /bin/x",
            "'up' /bin/x",
            "u\\p /bin/x",
            "\u{0B}up /bin/x",
            "up\u{0C}/bin/x",
            "\rup /bin/x",
            "\u{00A0}up /bin/x",
        ]
        for line in disguised {
            let report = OpenVPNConfig.check("remote a.example\n\(line)\n")
            XCTAssertFalse(report.isUsable, "accepted: \(line.debugDescription)")
            XCTAssertFalse(report.sanitized.contains("/bin/x"), "kept: \(line.debugDescription)")
        }
    }

    func testOnlyKeyMaterialBlocksAreInline() {
        let report = OpenVPNConfig.check("remote a.example\n<connection>\nremote b.example\nup /bin/x\n</connection>\n<ca>\nPEM\n</ca>\n")
        XCTAssertFalse(report.isUsable)
        XCTAssertFalse(report.sanitized.contains("/bin/x"))
        XCTAssertTrue(report.sanitized.contains("<ca>\nPEM\n</ca>"))
    }

    /// openvpn closes a block at any line that starts with the closing tag, so
    /// "</ca>x" would end the block for openvpn and expose the next line.
    func testBlockEndsOnlyAtTheExactClosingTag() {
        let report = OpenVPNConfig.check("remote a.example\n<ca>\nPEM\n</ca>x\nup /bin/x\n<ca>\n</ca>\n")
        XCTAssertFalse(report.isUsable)
        XCTAssertTrue(report.problems.contains { $0.contains("only </ca> may start with '<'") })
    }

    func testFileReferencesAreProblems() {
        let report = OpenVPNConfig.check("remote example.org\nca ca.crt\ntls-auth ta.key 1\n")
        XCTAssertFalse(report.isUsable)
        XCTAssertEqual(report.problems.count, 2)
    }

    func testMissingRemoteAndOpenBlock() {
        let report = OpenVPNConfig.check("client\n<ca>\n-----BEGIN CERTIFICATE-----\n")
        XCTAssertEqual(report.problems.count, 2)
    }

    func testWindowsLineEndings() {
        let report = OpenVPNConfig.check("remote a.example\r\nauth-user-pass\r\n")
        XCTAssertTrue(report.needsCredentials)
        XCTAssertFalse(report.sanitized.contains("\r"))
    }
}

final class ManagementTests: XCTestCase {
    /// Lines openvpn 2.7 sends during a connect, plus the documented password events.
    func testParse() {
        XCTAssertEqual(ManagementProtocol.parse(">HOLD:Waiting for hold release:0"), .hold)
        XCTAssertEqual(ManagementProtocol.parse(">PASSWORD:Need 'Auth' username/password"), .needCredentials(realm: "Auth"))
        XCTAssertEqual(ManagementProtocol.parse(">PASSWORD:Need 'Private Key' password"), .needSecret(realm: "Private Key"))
        XCTAssertEqual(ManagementProtocol.parse(">PASSWORD:Verification Failed: 'Auth'"), .authFailed(realm: "Auth"))
        XCTAssertEqual(ManagementProtocol.parse(">STATE:1795105941,CONNECTED,SUCCESS,10.8.0.6,198.51.100.16,1194,,"), .state("CONNECTED"))
        XCTAssertEqual(ManagementProtocol.parse(">STATE:1795105930,AUTH,,,,,,"), .state("AUTH"))
        XCTAssertEqual(ManagementProtocol.parse("1795106119,EXITING,exit-with-notification,,,,,"), .state("EXITING"))
        XCTAssertEqual(ManagementProtocol.parse(">INFO:OpenVPN Management Interface Version 6 -- type 'help' for more info"),
                       .info("OpenVPN Management Interface Version 6 -- type 'help' for more info"))
        XCTAssertEqual(ManagementProtocol.parse("ENTER PASSWORD:SUCCESS: password is correct"), .success("password is correct"))
        XCTAssertEqual(ManagementProtocol.parse("ERROR: unknown command"), .error("unknown command"))
        XCTAssertEqual(ManagementProtocol.parse("END"), .end)
    }

    func testCredentialCommandsEscape() {
        XCTAssertEqual(
            ManagementProtocol.credentialCommands(realm: "Auth", username: "alice@example.edu", password: #"p"a\ss"#),
            [#"username "Auth" "alice@example.edu""#, #"password "Auth" "p\"a\\ss""#]
        )
        XCTAssertNil(ManagementProtocol.credentialCommands(realm: "Auth", username: "u", password: "line\nbreak"))
    }
}
