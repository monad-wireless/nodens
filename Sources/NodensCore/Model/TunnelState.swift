import Foundation

/// The state of one VPN profile, in OpenVPN's management vocabulary: EXITING (or
/// nothing) when idle, CONNECTED when up, and RESOLVE, WAIT, AUTH, GET_CONFIG,
/// ASSIGN_IP, ADD_ROUTES, RECONNECTING and others in between. The WireGuard
/// driver reports only EXITING and CONNECTED.
public enum TunnelState: Sendable, Equatable {
    case disconnected
    case connecting(String)
    case connected

    public static func classify(_ raw: String) -> TunnelState {
        let state = raw.trimmed.uppercased()
        switch state {
        case "CONNECTED": return .connected
        case "EXITING", "": return .disconnected
        default: return .connecting(state)
        }
    }
}

/// A profile name with its engine state, as the policies and the glyph see it.
public struct TunnelConfig: Sendable, Equatable, Identifiable {
    public let name: String
    public let rawState: String

    public init(name: String, rawState: String) {
        self.name = name
        self.rawState = rawState
    }

    public var id: String { name }
    public var state: TunnelState { TunnelState.classify(rawState) }
}
