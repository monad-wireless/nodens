import AppKit
import Foundation
import NodensArt
import NodensCore
import SwiftUI

/// The state behind the menu and the settings window, and the actions they run.
///
/// Engines sit behind `TunnelDriver`; Tailscale's DNS handling sits in
/// `TailscaleCoexistence`. Two independent polls keep the state fresh, and one
/// action runs at a time (`exclusive`).
@MainActor
final class AppModel: ObservableObject {
    // Tailscale
    @Published private(set) var status: TailscaleStatus?
    @Published private(set) var tailnets: [TailscaleProfile] = []
    // VPN profiles
    @Published private(set) var profiles: [VPNProfile] = ProfileStore.load()
    @Published private(set) var revision = 0 // bumps when an engine state changes
    @Published private(set) var staleTunnels: [String] = []
    @Published private(set) var tailnetDomains: [String] = []
    // Status lines
    @Published private(set) var busy: String?
    @Published private(set) var message: String?
    @Published private(set) var dnsLine: String?
    @Published private(set) var actionFailed = false
    @Published private(set) var dnsFailed = false
    @Published private(set) var changingTunnel: String?
    @Published private(set) var changingTailnet = false
    // Settings
    @Published var keepTailnetNames: Bool = UserDefaults.standard.object(forKey: "keepTailnetNames") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepTailnetNames, forKey: "keepTailnetNames") }
    }
    @Published var openvpnPath: String = UserDefaults.standard.string(forKey: "openvpnPath")
        ?? EngineLocator.suggestedOpenVPN() ?? EngineLocator.homebrewOpenVPN {
        didSet { UserDefaults.standard.set(openvpnPath, forKey: "openvpnPath") }
    }
    @Published var wgQuickPath: String = UserDefaults.standard.string(forKey: "wgQuickPath") ?? EngineLocator.homebrewWgQuick {
        didSet { UserDefaults.standard.set(wgQuickPath, forKey: "wgQuickPath") }
    }
    @Published var routeStrategy: RouteStrategy = RouteStrategy(rawValue: UserDefaults.standard.string(forKey: "routeStrategy") ?? "") ?? .hostRoutes {
        didSet { UserDefaults.standard.set(routeStrategy.rawValue, forKey: "routeStrategy") }
    }

    let tailscale = TailscaleClient.locate()
    private let coexistence: TailscaleCoexistence
    private let openvpn = OpenVPNDriver()
    private let wireguard = WireGuardDriver()
    private var drivers: [TunnelDriver] { [openvpn, wireguard] }

    private var refreshingTailscale = false
    private var refreshingTunnels = false
    private var operationInFlight = false
    /// Counts finished actions. A tunnel read that spans an action is stale.
    private var actionEpoch = 0
    private var loops: [Task<Void, Never>] = []

    init() {
        coexistence = TailscaleCoexistence(client: tailscale)
        openvpn.onChange = { [weak self] in self?.revision += 1 }
        openvpn.onFailure = { [weak self] text in self?.fail(text) }
        // Two independent polls: a stuck tunnel must not stall the Tailscale rows.
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTailscale()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        })
        loops.append(Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshTunnels()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        })
    }

    // MARK: Engine state

    private func driver(for profile: VPNProfile) -> TunnelDriver {
        switch profile.kind {
        case .openvpn: return openvpn
        case .wireguard: return wireguard
        }
    }

    /// "EXITING" when idle, "CONNECTED" when up, nil when unknown.
    func rawState(_ profile: VPNProfile) -> String? {
        driver(for: profile).rawState(profile)
    }

    /// One row per profile. "UNKNOWN" when an engine runs that Nodens cannot reach.
    var tunnels: [TunnelConfig] {
        _ = revision
        return profiles.map { TunnelConfig(name: $0.name, rawState: rawState($0) ?? "UNKNOWN") }
    }

    /// The tunnel states, or nil unless every one is proven.
    private var knownTunnels: [TunnelConfig]? {
        var list: [TunnelConfig] = []
        for profile in profiles {
            guard let raw = rawState(profile) else { return nil }
            list.append(TunnelConfig(name: profile.name, rawState: raw))
        }
        return list
    }

    // MARK: Menu-bar glyph

    var glyphSpec: GlyphSpec {
        GlyphSpec(
            tailnet: StatusGlyph.tailnetState(backend: status?.backendState, changing: changingTailnet),
            vpn: StatusGlyph.vpnState(tunnels: tunnels, changing: changingTunnel != nil),
            attention: actionFailed || dnsFailed || !staleTunnels.isEmpty
        )
    }

    var statusImage: NSImage { GlyphRenderer.image(glyphSpec) }
    var statusDescription: String { StatusGlyph.describe(glyphSpec) }

    // MARK: Menu rows

    var tailscaleAvailable: Bool { tailscale.isInstalled }

    func title(for tailnet: TailscaleProfile) -> String {
        let name = "\(tailnet.tailnet) · \(tailnet.account)"
        guard tailnet.isCurrent else { return name }
        if changingTailnet { return "\(name) · changing…" }
        return "\(name) · \(status?.backendState ?? "unknown")"
    }

    func symbol(for tailnet: TailscaleProfile) -> String {
        guard tailnet.isCurrent else { return "arrow.left.arrow.right" }
        return Self.symbol(StatusGlyph.tailnetState(backend: status?.backendState, changing: changingTailnet))
    }

    func title(for profile: VPNProfile) -> String {
        if changingTunnel == profile.name { return "\(profile.name) · \(busy ?? "changing…")" }
        switch TunnelState.classify(rawState(profile) ?? "UNKNOWN") {
        case .connected: return "\(profile.name) · Connected"
        case .connecting(let raw): return "\(profile.name) · \(raw.capitalized)…"
        case .disconnected: return profile.name
        }
    }

    func symbol(for profile: VPNProfile) -> String {
        if changingTunnel == profile.name { return Self.symbol(.transition) }
        return Self.symbol(StatusGlyph.ring(TunnelState.classify(rawState(profile) ?? "UNKNOWN")))
    }

    /// Menu rows use the glyph's language: outline, outline with a dot, filled.
    static func symbol(_ state: RingState) -> String {
        switch state {
        case .off: return "circle"
        case .transition: return "smallcircle.filled.circle"
        case .on: return "circle.fill"
        }
    }

    // MARK: Profile editing

    func profile(_ id: UUID) -> VPNProfile? { profiles.first { $0.id == id } }

    func addProfile(_ kind: DriverKind) -> UUID {
        var name = "New \(kind.title)"
        var number = 2
        while profiles.contains(where: { $0.name == name }) {
            name = "New \(kind.title) \(number)"
            number += 1
        }
        let profile = VPNProfile(name: name, kind: kind, config: "")
        profiles.append(profile)
        persist()
        return profile.id
    }

    /// Saves a profile and, when given, its password. Returns an error text or nil.
    func save(_ profile: VPNProfile, password: String?) -> String? {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return "The profile no longer exists." }
        let name = profile.name.trimmed
        guard !name.isEmpty else { return "The name is empty." }
        guard !profiles.contains(where: { $0.id != profile.id && $0.name == name }) else { return "Another profile is called \(name)." }
        // A running tunnel is found by its name (slug) and, for WireGuard, by the
        // Address in its config: both must not change under it.
        let old = profiles[index]
        if rawState(old) != "EXITING", old.name != name || old.config != profile.config || old.kind != profile.kind {
            return "Disconnect \(old.name) before you change its name or configuration."
        }
        var updated = profile
        updated.name = name
        profiles[index] = updated
        if let password, !password.isEmpty, !Keychain.setPassword(password, for: profile.id, label: name) {
            return "The Keychain did not store the password."
        }
        return persist()
    }

    func delete(_ id: UUID) -> String? {
        guard let profile = profile(id) else { return nil }
        guard rawState(profile) == "EXITING" else { return "Disconnect \(profile.name) before you delete it." }
        profiles.removeAll { $0.id == id }
        Keychain.deletePassword(for: id)
        return persist()
    }

    /// Adds every Tunnelblick configuration whose name is not taken yet.
    func importFromTunnelblick() -> Int {
        var added = 0
        for (name, config) in ProfileStore.tunnelblickConfigs() where !profiles.contains(where: { $0.name == name }) {
            profiles.append(VPNProfile(name: name, kind: .openvpn, config: config))
            added += 1
        }
        if added > 0 { persist() }
        return added
    }

    @discardableResult
    private func persist() -> String? {
        do {
            try ProfileStore.save(profiles)
            return nil
        } catch {
            return "Could not save the profiles: \(error.localizedDescription)"
        }
    }

    // MARK: Menu actions

    func tapProfile(_ profile: VPNProfile) {
        Task { await self.toggle(profile) }
    }

    func tapTailnet(_ tailnet: TailscaleProfile) {
        Task { await self.tailnetAction(tailnet) }
    }

    func undoLeftovers() {
        Task {
            await self.rootMaintenance(
                label: "Undoing leftover VPN changes…",
                prompt: "Nodens undoes routes, IPv6 and DNS changes of tunnels that no longer run.",
                success: "Leftover changes undone"
            ) { AdminScript.cleanup(hookSource: $0) }
        }
    }

    func removeTailnetResolverFiles() {
        Task {
            await self.rootMaintenance(
                label: "Removing tailnet DNS files…",
                prompt: "Nodens removes the tailnet DNS files it wrote to /etc/resolver.",
                success: "Removed the tailnet DNS files"
            ) { AdminScript.clearTailnetResolvers(hookSource: $0) }
        }
    }

    private func rootMaintenance(label: String, prompt: String, success: String, command: (String) -> String) async {
        await exclusive(label) {
            guard let hook = Admin.hookSource else {
                self.fail("The hook is missing from the app bundle.")
                return
            }
            switch await Admin.run(command(hook), prompt: prompt) {
            case .done: self.note(success)
            case .cancelled: self.note("Admin prompt cancelled")
            case .failed(let reason): self.fail("\(label.dropLast()) failed: \(reason)")
            }
        }
        await refreshTunnels()
    }

    // MARK: Polling and restore

    func refreshTailscale() async {
        guard !refreshingTailscale else { return }
        refreshingTailscale = true
        defer { refreshingTailscale = false }
        let client = tailscale
        async let newStatus = client.status()
        async let newProfiles = client.profiles()
        status = await newStatus
        if let fetched = await newProfiles { tailnets = fetched }
    }

    func refreshTunnels() async {
        guard !refreshingTunnels else { return }
        refreshingTunnels = true
        defer { refreshingTunnels = false }
        let epochAtStart = actionEpoch
        let startedIdle = !operationInFlight
        for driver in drivers {
            await driver.poll(profiles.filter { $0.kind == driver.kind })
        }
        staleTunnels = HookState.staleTunnels()
        tailnetDomains = HookState.tailnetDomains()
        revision += 1
        // Only a read that began after the last action ended may decide a restore.
        guard startedIdle, !operationInFlight, epochAtStart == actionEpoch, let known = knownTunnels else { return }
        // A VPN engine Nodens does not know (another tool, a crash) makes the state unknown.
        if known.allSatisfy({ $0.state == .disconnected }), await HookState.anyVPNProcess() != false { return }
        guard let profileID = await coexistence.restoreCandidate(tunnels: known, operationInFlight: operationInFlight) else { return }
        await exclusive("Turning Tailscale DNS back on…", fromMenu: false) {
            if await self.coexistence.restore(profileID) { self.note("Tailscale DNS is on again") }
        }
    }

    // MARK: Connect and disconnect

    private func toggle(_ profile: VPNProfile) async {
        if rawState(profile) == "EXITING" {
            await connect(profile)
        } else {
            await disconnect(profile)
        }
    }

    private func plan(hook: String, infrastructure: [String], tailnetEntries: [ResolverEntry]) -> ConnectPlan {
        ConnectPlan(
            openvpn: openvpnPath,
            wgQuick: wgQuickPath,
            hookSource: hook,
            routeStrategy: routeStrategy,
            infrastructureIPv4: infrastructure,
            tailnetEntries: tailnetEntries
        )
    }

    private func connect(_ profile: VPNProfile) async {
        await exclusive("Connecting \(profile.name)…") {
            self.changingTunnel = profile.name
            defer { self.changingTunnel = nil }
            self.dnsLine = nil
            self.dnsFailed = false
            guard let hook = Admin.hookSource else {
                self.fail("The hook is missing from the app bundle. Run the app built by 'make app'.")
                return
            }

            let preparation: TailscaleCoexistence.Preparation
            switch await self.coexistence.prepare(routeStrategy: self.routeStrategy, keepTailnetNames: self.keepTailnetNames) {
            case .success(let value): preparation = value
            case .failure(let error):
                self.fail("\(profile.name) not connected: \(error.message)")
                return
            }
            if let status = preparation.status { self.status = status }

            let plan = self.plan(hook: hook, infrastructure: preparation.infrastructureIPv4, tailnetEntries: preparation.tailnetEntries)
            let driver = self.driver(for: profile)
            let error = await driver.connect(profile, plan: plan) {
                guard preparation.tailscaleRunning, self.keepTailnetNames else { return true }
                if let problem = await self.coexistence.leaveDefaultDNS() {
                    self.fail(problem)
                    return false
                }
                return true
            }
            if let error {
                self.fail("\(profile.name): \(error)")
                return
            }
            let final = await self.waitFor(profile, target: .connected, seconds: driver.connectTimeout)
            if final == .connected {
                self.note("\(profile.name) connected")
                await self.runDNSCheck()
            } else if !self.actionFailed {
                self.fail("\(profile.name) did not connect (\(Self.describe(final))). Log: \(HookPaths.log(profile.slug))")
            }
        }
    }

    private func disconnect(_ profile: VPNProfile) async {
        await exclusive("Disconnecting \(profile.name)…") {
            self.changingTunnel = profile.name
            defer { self.changingTunnel = nil }
            self.dnsLine = nil
            self.dnsFailed = false
            guard let hook = Admin.hookSource else {
                self.fail("The hook is missing from the app bundle.")
                return
            }
            let plan = self.plan(hook: hook, infrastructure: [], tailnetEntries: [])
            if let error = await self.driver(for: profile).disconnect(profile, plan: plan) {
                self.fail("\(profile.name): \(error)")
                return
            }
            let final = await self.waitFor(profile, target: .disconnected, seconds: 30)
            if final == .disconnected {
                self.note("\(profile.name) disconnected")
            } else {
                self.fail("\(profile.name) is still \(Self.describe(final))")
            }
        }
        // The next poll turns Tailscale DNS back on once every tunnel is idle.
        await refreshTunnels()
    }

    private func waitFor(_ profile: VPNProfile, target: TunnelState, seconds: Int) async -> TunnelState? {
        var last: TunnelState?
        var sawTransition = false
        for tick in 0..<(seconds * 2) {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let raw = rawState(profile) else { continue }
            let state = TunnelState.classify(raw)
            last = state
            if state == target { return state }
            if case .connecting(let name) = state {
                sawTransition = true
                busy = "\(name.capitalized)…"
            }
            if target == .connected, state == .disconnected, sawTransition || tick >= 20 { return state }
        }
        return last
    }

    private func runDNSCheck() async {
        async let publicOK = DNSCheck.resolves("www.wikipedia.org")
        var tailnetOK: Bool?
        if status?.isRunning == true, let name = status?.selfDNSName {
            tailnetOK = await DNSCheck.resolves(name)
        }
        let publicResult = await publicOK
        dnsFailed = !publicResult || tailnetOK == false
        let tailnetText = tailnetOK.map { $0 ? "OK" : "FAIL" } ?? "n/a"
        dnsLine = "DNS: public \(publicResult ? "OK" : "FAIL"), tailnet \(tailnetText)"
    }

    // MARK: Tailscale

    private func tailnetAction(_ tailnet: TailscaleProfile) async {
        let label = tailnet.isCurrent ? "Tailscale…" : "Switching to \(tailnet.tailnet)…"
        await exclusive(label) {
            let running = self.status?.isRunning == true
            // "down" is always safe. "up" and "switch" give Tailscale the default
            // resolver again, so they wait until no VPN engine runs.
            if !(tailnet.isCurrent && running), await HookState.anyVPNProcess() != false {
                self.note("Disconnect the VPN first")
                return
            }
            self.changingTailnet = true
            defer { self.changingTailnet = false }
            let result: ProcessResult?
            if tailnet.isCurrent {
                result = running ? await self.tailscale.down() : await self.tailscale.up()
            } else {
                result = await self.tailscale.switchTo(tailnet.id)
            }
            if result?.succeeded != true {
                self.fail("tailscale: \(result?.stderr.trimmed ?? "CLI not found")")
            }
        }
        await refreshTailscale()
    }

    // MARK: Helpers

    /// Runs one action at a time. The restore rule reads `operationInFlight` and
    /// `actionEpoch`. A menu action clears the previous message and failure.
    private func exclusive(_ label: String, fromMenu: Bool = true, _ body: () async -> Void) async {
        guard !operationInFlight else {
            message = "Busy: \(busy ?? "another action")"
            return
        }
        operationInFlight = true
        busy = label
        if fromMenu {
            message = nil
            actionFailed = false
        }
        await body()
        busy = nil
        operationInFlight = false
        actionEpoch += 1
    }

    private func note(_ text: String) {
        if let existing = message, !existing.isEmpty {
            message = "\(existing). \(text)"
        } else {
            message = text
        }
    }

    private func fail(_ text: String) {
        actionFailed = true
        note(text)
    }

    private static func describe(_ state: TunnelState?) -> String {
        switch state {
        case .connected?: return "connected"
        case .disconnected?: return "disconnected"
        case .connecting(let raw)?: return raw.lowercased()
        case nil: return "state unknown"
        }
    }
}
