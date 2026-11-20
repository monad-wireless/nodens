import Foundation

/// The engine a profile uses. Tailscale profiles are not stored: they come from
/// `tailscale switch --list`.
public enum DriverKind: String, Codable, Sendable, CaseIterable {
    case openvpn
    case wireguard

    public var title: String {
        switch self {
        case .openvpn: return "OpenVPN"
        case .wireguard: return "WireGuard"
        }
    }

    /// What the user pastes.
    public var fileHint: String {
        switch self {
        case .openvpn: return "the .ovpn file"
        case .wireguard: return "the WireGuard .conf file"
        }
    }
}

/// One VPN the menu can connect: a pasted configuration plus a name.
/// The password never lives here; it is in the Keychain under the profile id.
public struct VPNProfile: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: DriverKind
    public var config: String
    public var username: String

    public init(id: UUID = UUID(), name: String, kind: DriverKind = .openvpn, config: String, username: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.config = config
        self.username = username
    }

    /// File-safe name for root-side files, the daemon and the WireGuard interface
    /// name (wg-quick allows at most 15 characters of [a-zA-Z0-9_=+.-]):
    /// [a-z0-9-], at most 15 characters, unique through a suffix taken from the id.
    public var slug: String { Self.slug(name: name, id: id) }

    public static func slug(name: String, id: UUID) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")
        var base = ""
        for character in name.lowercased() {
            if allowed.contains(character) {
                base.append(character)
            } else if !base.isEmpty, !base.hasSuffix("-") {
                base.append("-")
            }
        }
        var short = String(base.prefix(10))
        while short.hasSuffix("-") { short.removeLast() }
        if short.isEmpty { short = "vpn" }
        return short + "-" + id.uuidString.lowercased().prefix(4)
    }
}
