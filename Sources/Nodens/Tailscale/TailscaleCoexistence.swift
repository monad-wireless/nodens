import Foundation
import NodensCore

/// Keeps Tailscale working while another VPN is connected.
///
/// Tailscale is normally the default DNS resolver (100.100.100.100). While a VPN
/// runs, Nodens writes /etc/resolver files for the tailnet's own domains, takes
/// Tailscale out of the default slot (`--accept-dns=false`), and turns it back
/// on once every tunnel is idle. See docs/TAILSCALE.md.
@MainActor
final class TailscaleCoexistence {
    /// What a connect needs from Tailscale, read before the tunnel exists.
    struct Preparation {
        let status: TailscaleStatus?
        let tailscaleRunning: Bool
        let infrastructureIPv4: [String]
        let tailnetEntries: [ResolverEntry]
    }

    let client: TailscaleClient

    private static let changedKey = "acceptDNSChangedProfiles"
    /// Tailscale profiles whose accept-dns Nodens turned off. Stored, so a
    /// restart of the app still restores them.
    private var changedProfiles: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.changedKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: Self.changedKey) }
    }

    init(client: TailscaleClient) {
        self.client = client
    }

    func prepare(routeStrategy: RouteStrategy, keepTailnetNames: Bool) async -> Result<Preparation, NodensError> {
        guard client.isInstalled else {
            return .success(Preparation(status: nil, tailscaleRunning: false, infrastructureIPv4: [], tailnetEntries: []))
        }
        guard let status = await client.status() else { return .failure(NodensError("could not read Tailscale status")) }
        guard status.isRunning else {
            return .success(Preparation(status: status, tailscaleRunning: false, infrastructureIPv4: [], tailnetEntries: []))
        }
        var infrastructure: [String] = []
        if routeStrategy == .hostRoutes {
            infrastructure = await client.infrastructureIPv4()
            if infrastructure.isEmpty {
                return .failure(NodensError("could not resolve the tailnet's control and relay servers"))
            }
        }
        var entries: [ResolverEntry] = []
        if keepTailnetNames {
            entries = ResolverPlan.entries(
                magicDNSSuffix: status.magicDNSSuffix,
                extraRecordNames: status.extraRecordNames,
                splitRoutes: await client.splitRoutes()
            )
        }
        return .success(Preparation(status: status, tailscaleRunning: true, infrastructureIPv4: infrastructure, tailnetEntries: entries))
    }

    /// Takes Tailscale out of the default resolver slot and waits until macOS
    /// shows it. Returns an error text, or nil.
    func leaveDefaultDNS() async -> String? {
        guard let accepts = await client.acceptsDNS() else { return "Could not read the Tailscale DNS setting" }
        guard accepts else { return nil } // already off; nothing to restore later
        guard let current = await client.profiles()?.first(where: \.isCurrent) else {
            return "Could not read the current Tailscale profile"
        }
        changedProfiles.insert(current.id) // before the change, so a crash still leads to a restore
        guard await client.setAcceptDNS(false) else {
            changedProfiles.remove(current.id)
            return "tailscale set --accept-dns=false failed"
        }
        for _ in 0..<20 {
            if await DNSCheck.tailscaleHoldsDefault() == false { return nil }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // The poll turns Tailscale DNS back on, because no tunnel comes up.
        return "Tailscale still held the default resolver after 10 s"
    }

    /// The Tailscale profile whose DNS may be turned back on now, or nil.
    func restoreCandidate(tunnels: [TunnelConfig], operationInFlight: Bool) async -> String? {
        let changed = changedProfiles
        guard !changed.isEmpty, !operationInFlight else { return nil }
        // Decide on the profile that is current now, not on a cached list.
        guard let current = await client.profiles()?.first(where: \.isCurrent) else { return nil }
        let allowed = RestorePolicy.shouldRestore(
            operationInFlight: operationInFlight,
            tunnels: tunnels,
            currentProfileID: current.id,
            changedProfiles: changed
        )
        return allowed ? current.id : nil
    }

    func restore(_ profileID: String) async -> Bool {
        guard await client.setAcceptDNS(true) else { return false }
        changedProfiles.remove(profileID)
        return true
    }
}
