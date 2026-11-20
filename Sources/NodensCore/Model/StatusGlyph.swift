import Foundation

/// One ring of the menu-bar glyph.
public enum RingState: String, Sendable, Hashable, CaseIterable {
    /// Faint outline.
    case off
    /// Outline with a center dot: connecting, disconnecting or switching.
    case transition
    /// Filled.
    case on
}

/// What the menu-bar glyph shows: the tailnet ring (left), the VPN ring (right)
/// and an attention badge on the VPN ring.
public struct GlyphSpec: Sendable, Hashable {
    public var tailnet: RingState
    public var vpn: RingState
    public var attention: Bool

    public init(tailnet: RingState, vpn: RingState, attention: Bool = false) {
        self.tailnet = tailnet
        self.vpn = vpn
        self.attention = attention
    }
}

public enum StatusGlyph {
    /// - Parameter changing: an up, down or switch started from the menu is in flight.
    public static func tailnetState(backend: String?, changing: Bool) -> RingState {
        if changing { return .transition }
        switch backend {
        case "Running"?: return .on
        case "Starting"?: return .transition
        default: return .off
        }
    }

    /// - Parameter changing: a connect or disconnect started from the menu is in flight.
    public static func vpnState(tunnels: [TunnelConfig], changing: Bool) -> RingState {
        if changing { return .transition }
        if tunnels.contains(where: { $0.state == .connected }) { return .on }
        if tunnels.contains(where: { ring($0.state) == .transition }) { return .transition }
        return .off
    }

    public static func ring(_ state: TunnelState) -> RingState {
        switch state {
        case .connected: return .on
        case .connecting: return .transition
        case .disconnected: return .off
        }
    }

    /// The glyph in words, for VoiceOver.
    public static func describe(_ spec: GlyphSpec) -> String {
        var text = "Tailscale \(word(spec.tailnet)), VPN \(word(spec.vpn))"
        if spec.attention { text += ", needs attention" }
        return text
    }

    static func word(_ state: RingState) -> String {
        switch state {
        case .off: return "off"
        case .transition: return "changing"
        case .on: return "on"
        }
    }
}
