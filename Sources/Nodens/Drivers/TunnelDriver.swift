import Foundation
import NodensCore

/// What every VPN engine driver offers the app.
///
/// A driver validates a profile, runs its engine as root through one admin
/// prompt, and reports the engine's state in OpenVPN's management vocabulary
/// ("EXITING" idle, "CONNECTED" up, other states in between).
@MainActor
protocol TunnelDriver: AnyObject {
    var kind: DriverKind { get }

    /// Seconds the app waits for "CONNECTED" after `connect` returns.
    var connectTimeout: Int { get }

    /// The engine state, or nil when an engine seems to run for the profile but
    /// the driver cannot reach it.
    func rawState(_ profile: VPNProfile) -> String?

    /// Validates the profile and starts its engine. `beforeTraffic` runs once the
    /// root side is ready and before the tunnel carries traffic; returning false
    /// stops the connect. Returns an error text, or nil when the start succeeded.
    func connect(_ profile: VPNProfile, plan: ConnectPlan, beforeTraffic: () async -> Bool) async -> String?

    /// Stops the engine. Returns an error text, or nil.
    func disconnect(_ profile: VPNProfile, plan: ConnectPlan) async -> String?

    /// Called by the tunnel poll every few seconds with this driver's profiles.
    func poll(_ profiles: [VPNProfile]) async
}

/// Everything a connect or disconnect needs besides the profile.
struct ConnectPlan {
    let openvpn: String
    let wgQuick: String
    /// The hook inside the app bundle; every admin command installs it.
    let hookSource: String
    let routeStrategy: RouteStrategy
    /// Tailnet control and relay servers, for `host-routes`.
    let infrastructureIPv4: [String]
    /// /etc/resolver entries that keep tailnet names working.
    let tailnetEntries: [ResolverEntry]
}

/// A private temporary folder for the files one admin command installs.
/// Root reads them from here; the folder is removed afterwards.
struct Staging {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nodens-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Writes a mode-600 file and returns its path.
    func write(_ text: String, as name: String) throws -> String {
        let url = directory.appendingPathComponent(name)
        try ProfileStore.writePrivate(text, to: url)
        return url.path
    }

    /// The host list and tailnet entries every driver installs.
    func rootSetup(slug: String, plan: ConnectPlan) throws -> RootSetup {
        let useHosts = plan.routeStrategy == .hostRoutes && !plan.infrastructureIPv4.isEmpty
        let entries = ResolverPlan.entriesFile(plan.tailnetEntries)
        return RootSetup(
            slug: slug,
            hookSource: plan.hookSource,
            stagedHosts: useHosts ? try write(plan.infrastructureIPv4.joined(separator: "\n") + "\n", as: "hosts") : nil,
            stagedTailnetEntries: entries.isEmpty ? nil : try write(entries, as: "tailnet.entries")
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// An error with a message for the menu.
struct NodensError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}
