import Foundation
import NodensCore

/// Runs a pasted WireGuard configuration with wg-quick and wireguard-go.
/// Up and down each take one admin prompt; WireGuard has no session to talk to.
@MainActor
final class WireGuardDriver: TunnelDriver {
    let kind = DriverKind.wireguard
    let connectTimeout = 15

    /// "CONNECTED" while a utun interface carries one of the profile's addresses.
    func rawState(_ profile: VPNProfile) -> String? {
        let addresses = WireGuardConfig.check(profile.config).addresses
        return Self.interfaceUp(addresses: addresses) ? "CONNECTED" : "EXITING"
    }

    /// wg-quick has no hold, so `beforeTraffic` runs before the admin prompt.
    func connect(_ profile: VPNProfile, plan: ConnectPlan, beforeTraffic: () async -> Bool) async -> String? {
        let report = WireGuardConfig.check(profile.config)
        guard report.isUsable else { return report.problems.joined(separator: " ") }
        guard FileManager.default.isExecutableFile(atPath: plan.wgQuick) else {
            return "No wg-quick at \(plan.wgQuick). Install it with 'brew install wireguard-tools wireguard-go bash'."
        }
        guard rawState(profile) == "EXITING" else { return "An interface with this profile's address is already up." }

        guard let staging = try? Staging() else { return "Could not create a private temporary folder." }
        defer { staging.remove() }
        let launch: WireGuardLaunch
        do {
            launch = WireGuardLaunch(
                setup: try staging.rootSetup(slug: profile.slug, plan: plan),
                wgQuick: plan.wgQuick,
                stagedConfig: try staging.write(
                    WireGuardConfig.rootConfig(report, slug: profile.slug, routeStrategy: plan.routeStrategy),
                    as: "\(profile.slug).conf"
                )
            )
        } catch {
            return "Could not prepare the files: \(error.localizedDescription)"
        }

        guard await beforeTraffic() else { return "Stopped before connecting." }
        switch await Admin.run(AdminScript.wireguardUp(launch), prompt: "Nodens starts WireGuard for “\(profile.name)”.") {
        case .done:
            return nil
        case .cancelled:
            return "Admin prompt cancelled."
        case .failed:
            return "wg-quick failed: \(HookState.tail(HookPaths.log(profile.slug)))"
        }
    }

    func disconnect(_ profile: VPNProfile, plan: ConnectPlan) async -> String? {
        let command = AdminScript.wireguardDown(wgQuick: plan.wgQuick, slug: profile.slug, hookSource: plan.hookSource)
        switch await Admin.run(command, prompt: "Nodens stops WireGuard for “\(profile.name)”.") {
        case .done: return nil
        case .cancelled: return "Admin prompt cancelled."
        case .failed(let reason): return "wg-quick down failed: \(reason)"
        }
    }

    /// Nothing to poll: `rawState` reads the interfaces on demand.
    func poll(_ profiles: [VPNProfile]) async {}

    /// True when a utun interface holds one of the addresses (no root needed).
    static func interfaceUp(addresses: [String]) -> Bool {
        let wanted = Set(addresses.map { $0.lowercased() })
        guard !wanted.isEmpty else { return false }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return false }
        defer { freeifaddrs(list) }
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard String(cString: entry.pointee.ifa_name).hasPrefix("utun"),
                  let address = entry.pointee.ifa_addr
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(cString: host).lowercased()
            if let scope = text.firstIndex(of: "%") { text = String(text[..<scope]) }
            if wanted.contains(text) { return true }
        }
        return false
    }
}
