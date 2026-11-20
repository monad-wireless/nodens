import Foundation
import NodensCore

/// The management port and password of a running tunnel, kept so the app can
/// attach again after a restart.
struct RunInfo: Codable {
    let port: Int
    let passwordFile: String
}

/// Runs openvpn as a root daemon and talks to it over its management interface.
///
/// openvpn starts held (`--management-hold`), so the app can finish its own
/// preparation before any traffic flows. Logins come from the Keychain and are
/// sent again after every reconnect, because servers may use `auth-nocache`.
@MainActor
final class OpenVPNDriver: TunnelDriver {
    private struct Entry {
        let session: ManagementSession
        let profile: VPNProfile
        /// False until `beforeTraffic` has run: a >HOLD is answered later.
        var mayRelease: Bool
    }

    let kind = DriverKind.openvpn
    let connectTimeout = 90

    private var entries: [UUID: Entry] = [:]
    private var states: [UUID: String] = [:]
    private var authFailed: Set<UUID> = []
    private var lastAttach: [UUID: Date] = [:]
    /// Profiles whose connect is running. The poll leaves them alone: their run
    /// file exists before their openvpn does.
    private var connecting: Set<UUID> = []

    var onChange: () -> Void = {}
    /// A failure the menu should show.
    var onFailure: (String) -> Void = { _ in }

    // MARK: TunnelDriver

    func rawState(_ profile: VPNProfile) -> String? {
        if entries[profile.id] != nil { return states[profile.id] ?? "CONNECTING" }
        if runInfo(profile) != nil, HookState.openvpnAlive(profile.slug) { return nil }
        return "EXITING"
    }

    func connect(_ profile: VPNProfile, plan: ConnectPlan, beforeTraffic: () async -> Bool) async -> String? {
        let report = OpenVPNConfig.check(profile.config)
        guard report.isUsable else { return report.problems.joined(separator: " ") }
        if report.needsCredentials, profile.username.isEmpty || !Keychain.hasPassword(for: profile.id) {
            return "\(profile.name) needs a username and password. Set them in Profiles."
        }
        guard FileManager.default.isExecutableFile(atPath: plan.openvpn) else {
            return "No openvpn at \(plan.openvpn). Install it with 'brew install openvpn', or pick another binary in Settings."
        }
        authFailed.remove(profile.id)
        connecting.insert(profile.id)
        defer { connecting.remove(profile.id) }

        let password = Self.randomToken()
        let passwordFile = ProfileStore.runDirectory.appendingPathComponent("\(profile.slug).pw")
        guard let port = Self.freeLocalPort() else { return "No free local port for the management interface." }
        guard let staging = try? Staging() else { return "Could not create a private temporary folder." }
        defer { staging.remove() }
        let launch: OpenVPNLaunch
        do {
            ProfileStore.ensureDirectories()
            try ProfileStore.writePrivate(password + "\n", to: passwordFile)
            try saveRunInfo(RunInfo(port: port, passwordFile: passwordFile.path), for: profile)
            launch = OpenVPNLaunch(
                setup: try staging.rootSetup(slug: profile.slug, plan: plan),
                openvpn: plan.openvpn,
                stagedConfig: try staging.write(report.sanitized, as: "config.ovpn"),
                managementPort: port,
                managementPasswordFile: passwordFile.path,
                routeStrategy: plan.routeStrategy
            )
        } catch {
            removeRunInfo(profile)
            return "Could not prepare the files: \(error.localizedDescription)"
        }

        switch await Admin.run(AdminScript.openvpnConnect(launch), prompt: "Nodens starts OpenVPN for “\(profile.name)”.") {
        case .done:
            break
        case .cancelled:
            removeRunInfo(profile)
            return "Admin prompt cancelled."
        case .failed(let reason):
            removeRunInfo(profile)
            return "openvpn did not start: \(reason) \(HookState.tail(HookPaths.launchLog(profile.slug)))"
        }

        // openvpn now waits on its hold. Attach first, release after beforeTraffic.
        var attached = false
        for _ in 0..<20 where !attached {
            attached = await attach(profile, RunInfo(port: port, passwordFile: passwordFile.path), mayRelease: false)
            if !attached { try? await Task.sleep(nanoseconds: 500_000_000) }
        }
        guard attached else {
            return "openvpn did not open its management port. \(HookState.tail(HookPaths.launchLog(profile.slug))) \(HookState.tail(HookPaths.log(profile.slug)))"
        }
        guard await beforeTraffic() else {
            entries[profile.id]?.session.send("signal SIGTERM")
            return "Stopped before connecting."
        }
        entries[profile.id]?.mayRelease = true
        entries[profile.id]?.session.send("hold release")
        return nil
    }

    func disconnect(_ profile: VPNProfile, plan: ConnectPlan) async -> String? {
        if let entry = entries[profile.id] {
            entry.session.send("signal SIGTERM")
            return nil
        }
        let command = AdminScript.openvpnKill(slug: profile.slug, hookSource: plan.hookSource)
        switch await Admin.run(command, prompt: "Nodens stops OpenVPN for “\(profile.name)”.") {
        case .done:
            removeRunInfo(profile)
            return nil
        case .cancelled:
            return "Admin prompt cancelled."
        case .failed(let reason):
            return "Could not stop openvpn: \(reason)"
        }
    }

    /// Attaches to tunnels started by an earlier run of the app and forgets the
    /// ones whose openvpn is gone.
    func poll(_ profiles: [VPNProfile]) async {
        for profile in profiles {
            let info = runInfo(profile)
            let recent = lastAttach[profile.id].map { Date().timeIntervalSince($0) < 10 } ?? false
            let decision = AttachPolicy.decide(
                connectInFlight: connecting.contains(profile.id),
                attached: entries[profile.id] != nil,
                hasRunInfo: info != nil,
                openvpnAlive: info != nil && HookState.openvpnAlive(profile.slug),
                triedRecently: recent
            )
            switch decision {
            case .skip:
                continue
            case .forget:
                removeRunInfo(profile)
            case .attach:
                guard let info else { continue }
                lastAttach[profile.id] = Date()
                _ = await attach(profile, info, mayRelease: true)
            }
        }
    }

    // MARK: Management session

    private func attach(_ profile: VPNProfile, _ info: RunInfo, mayRelease: Bool) async -> Bool {
        guard let password = try? String(contentsOfFile: info.passwordFile, encoding: .utf8).trimmed else { return false }
        let id = profile.id
        let session = ManagementSession(
            port: info.port,
            password: password,
            onEvent: { [weak self] event in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, for: id) } }
            },
            onClose: { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.closed(id) } }
            }
        )
        // Registered before it opens: openvpn sends a pending >HOLD or
        // >PASSWORD at once, and an event for an unknown profile is dropped.
        entries[id] = Entry(session: session, profile: profile, mayRelease: mayRelease)
        let opened = await Task.detached { session.open() }.value
        guard opened else {
            if entries[id]?.session === session { entries[id] = nil }
            return false
        }
        // A restart after ping-restart must not wait for the app again.
        session.send("state on")
        session.send("state")
        session.send("hold off")
        if mayRelease { session.send("hold release") }
        onChange()
        return true
    }

    private func handle(_ event: ManagementEvent, for id: UUID) {
        guard let entry = entries[id] else { return }
        let name = entry.profile.name
        switch event {
        case .hold:
            if entry.mayRelease { entry.session.send("hold release") }
        case .needCredentials(let realm):
            guard !authFailed.contains(id) else {
                entry.session.send("signal SIGTERM")
                return
            }
            guard let password = Keychain.password(for: id),
                  !entry.profile.username.isEmpty,
                  let commands = ManagementProtocol.credentialCommands(realm: realm, username: entry.profile.username, password: password)
            else {
                onFailure("\(name): no usable username and password. Set them in Profiles.")
                entry.session.send("signal SIGTERM")
                return
            }
            commands.forEach(entry.session.send)
        case .needSecret(let realm):
            onFailure("\(name) asks for '\(realm)', which Nodens cannot provide.")
            entry.session.send("signal SIGTERM")
        case .authFailed:
            authFailed.insert(id)
            onFailure("\(name): the server rejected the username or password.")
            entry.session.send("signal SIGTERM")
        case .state(let state):
            states[id] = state
            onChange()
        case .success, .error, .info, .end, .other:
            break
        }
    }

    private func closed(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        states[id] = nil
        if !HookState.openvpnAlive(entry.profile.slug) { removeRunInfo(entry.profile) }
        onChange()
    }

    // MARK: Run files

    private func runInfoURL(_ profile: VPNProfile) -> URL {
        ProfileStore.runDirectory.appendingPathComponent("\(profile.slug).json")
    }

    private func runInfo(_ profile: VPNProfile) -> RunInfo? {
        guard let data = try? Data(contentsOf: runInfoURL(profile)) else { return nil }
        return try? JSONDecoder().decode(RunInfo.self, from: data)
    }

    private func saveRunInfo(_ info: RunInfo, for profile: VPNProfile) throws {
        try ProfileStore.writePrivate(String(decoding: try JSONEncoder().encode(info), as: UTF8.self), to: runInfoURL(profile))
    }

    private func removeRunInfo(_ profile: VPNProfile) {
        try? FileManager.default.removeItem(at: runInfoURL(profile))
        try? FileManager.default.removeItem(at: ProfileStore.runDirectory.appendingPathComponent("\(profile.slug).pw"))
    }

    private static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A free TCP port on 127.0.0.1, chosen by the kernel.
    private static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
