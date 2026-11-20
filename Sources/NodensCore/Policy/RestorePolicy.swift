import Foundation

/// When Nodens may turn Tailscale DNS back on.
///
/// Only on positive evidence: no connect or disconnect in flight, a successful
/// read of every tunnel, every tunnel idle, and the current Tailscale profile is
/// one Nodens changed. A failed or timed-out read is unknown, never "all idle".
public enum RestorePolicy {
    /// - Parameter tunnels: the last tunnel read, or nil when it failed.
    public static func shouldRestore(
        operationInFlight: Bool,
        tunnels: [TunnelConfig]?,
        currentProfileID: String?,
        changedProfiles: Set<String>
    ) -> Bool {
        guard !operationInFlight, let tunnels else { return false }
        guard tunnels.allSatisfy({ $0.state == .disconnected }) else { return false }
        guard let currentProfileID else { return false }
        return changedProfiles.contains(currentProfileID)
    }
}
