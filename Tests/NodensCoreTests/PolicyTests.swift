import XCTest
@testable import NodensCore

final class RestorePolicyTests: XCTestCase {
    private let idle = [TunnelConfig(name: "Work", rawState: "EXITING"), TunnelConfig(name: "Home", rawState: "EXITING")]

    private func decide(
        inFlight: Bool = false,
        tunnels: [TunnelConfig]?,
        current: String? = "p1",
        changed: Set<String> = ["p1"]
    ) -> Bool {
        RestorePolicy.shouldRestore(
            operationInFlight: inFlight,
            tunnels: tunnels,
            currentProfileID: current,
            changedProfiles: changed
        )
    }

    func testRestoresWhenEveryTunnelIsIdle() {
        XCTAssertTrue(decide(tunnels: idle))
    }

    func testRestoresWhenThereAreNoProfiles() {
        XCTAssertTrue(decide(tunnels: []))
    }

    func testUnknownTunnelStateNeverRestores() {
        XCTAssertFalse(decide(tunnels: nil))
    }

    func testNeverRestoresDuringAConnect() {
        XCTAssertFalse(decide(inFlight: true, tunnels: idle))
    }

    func testNeverRestoresWhileATunnelIsUpOrComingUp() {
        XCTAssertFalse(decide(tunnels: [TunnelConfig(name: "Work", rawState: "CONNECTED")]))
        XCTAssertFalse(decide(tunnels: [TunnelConfig(name: "Work", rawState: "AUTH")]))
    }

    func testOnlyRestoresProfilesNodensChanged() {
        XCTAssertFalse(decide(tunnels: idle, changed: ["p2"]))
        XCTAssertFalse(decide(tunnels: idle, current: nil))
    }
}

final class AttachPolicyTests: XCTestCase {
    private func decide(
        inFlight: Bool = false, attached: Bool = false, runInfo: Bool = true, alive: Bool = true, recent: Bool = false
    ) -> AttachDecision {
        AttachPolicy.decide(connectInFlight: inFlight, attached: attached, hasRunInfo: runInfo, openvpnAlive: alive, triedRecently: recent)
    }

    /// The connect writes the run file before openvpn exists (the admin prompt
    /// is still open). The poll must neither delete it nor attach.
    func testConnectInFlightIsNeverTouched() {
        XCTAssertEqual(decide(inFlight: true, alive: false), .skip)
        XCTAssertEqual(decide(inFlight: true, alive: true), .skip)
    }

    func testAttachToARunningTunnelAfterARestart() {
        XCTAssertEqual(decide(), .attach)
        XCTAssertEqual(decide(recent: true), .skip)
    }

    func testForgetATunnelWhoseOpenVPNIsGone() {
        XCTAssertEqual(decide(alive: false), .forget)
        XCTAssertEqual(decide(alive: false, recent: true), .forget)
    }

    func testNothingToDo() {
        XCTAssertEqual(decide(attached: true), .skip)
        XCTAssertEqual(decide(runInfo: false), .skip)
    }
}
