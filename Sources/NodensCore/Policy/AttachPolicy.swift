import Foundation

/// What the tunnel poll does with an OpenVPN profile that has a run file
/// (management port and password) but no management session.
public enum AttachDecision: Sendable, Equatable {
    /// Leave it alone this time.
    case skip
    /// Connect to openvpn's management port.
    case attach
    /// The openvpn is gone: delete the run file and the password file.
    case forget
}

public enum AttachPolicy {
    /// - Parameters:
    ///   - connectInFlight: a connect for this profile is running. Its run file
    ///     exists before openvpn does, so the poll must not touch it.
    ///   - attached: a session already exists.
    ///   - hasRunInfo: the run file exists.
    ///   - openvpnAlive: the pid file names a live process.
    ///   - triedRecently: the last attach attempt was less than 10 s ago.
    public static func decide(
        connectInFlight: Bool,
        attached: Bool,
        hasRunInfo: Bool,
        openvpnAlive: Bool,
        triedRecently: Bool
    ) -> AttachDecision {
        if connectInFlight || attached || !hasRunInfo { return .skip }
        if !openvpnAlive { return .forget }
        return triedRecently ? .skip : .attach
    }
}
