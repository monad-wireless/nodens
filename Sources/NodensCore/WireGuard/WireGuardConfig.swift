import Foundation

/// The result of checking a pasted wg-quick .conf file.
public struct WireGuardConfigReport: Sendable, Equatable {
    /// The file without the keys Nodens owns (DNS, Pre/PostUp/Down, SaveConfig).
    public let sanitized: String
    /// Keys Nodens removed, in file order.
    public let removed: [String]
    /// IP addresses of the interface, without prefix lengths.
    public let addresses: [String]
    /// DNS servers and search domains from the `DNS =` line.
    public let dnsServers: [String]
    public let dnsDomains: [String]
    /// `DNS =` entries that are neither an IP address nor a domain of two or more labels.
    public let ignoredDNS: [String]
    public let endpoints: [String]
    /// AllowedIPs contains 0.0.0.0/0 or ::/0 (and Table is not off).
    public let fullTunnelIPv4: Bool
    public let fullTunnelIPv6: Bool
    public let problems: [String]

    public var isUsable: Bool { problems.isEmpty }
}

/// wg-quick runs Pre/PostUp/Down hooks with bash `eval` as root, so the check is
/// an allow-list that fails closed: only known keys pass, and a control
/// character anywhere makes the file unusable (bash trims \v, \f and \r from a
/// key, which would let a hidden PostUp through a deny-list).
public enum WireGuardConfig {
    /// [Interface] keys Nodens owns and removes.
    static let removedInterfaceKeys: [String: String] = [
        "dns": "DNS", "preup": "PreUp", "postup": "PostUp", "predown": "PreDown",
        "postdown": "PostDown", "saveconfig": "SaveConfig",
    ]
    /// Keys wg-quick and `wg setconf` understand, minus the removed ones.
    static let interfaceKeys: Set<String> = ["privatekey", "listenport", "fwmark", "address", "mtu", "table"]
    static let peerKeys: Set<String> = ["publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"]

    private static let spaceAndTab = CharacterSet(charactersIn: " \t")

    static func hasControlCharacter(_ line: String) -> Bool {
        line.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }
    }

    public static func check(_ text: String) -> WireGuardConfigReport {
        var output: [String] = []
        var removed: [String] = []
        var addresses: [String] = []
        var servers: [String] = []
        var domains: [String] = []
        var ignored: [String] = []
        var endpoints: [String] = []
        var full4 = false
        var full6 = false
        var tableOff = false
        var problems: [String] = []

        var section = ""
        var interfaceCount = 0
        var hasPrivateKey = false
        var peerHasKey: [Bool] = []

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let number = index + 1
            if hasControlCharacter(rawLine) {
                problems.append("Line \(number) contains a control character.")
                continue
            }
            // wg-quick treats everything after '#' as a comment.
            let content = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = content.trimmingCharacters(in: spaceAndTab)
            if trimmed.isEmpty {
                output.append(rawLine)
                continue
            }

            if trimmed.hasPrefix("[") {
                switch trimmed.lowercased() {
                case "[interface]":
                    section = "interface"
                    interfaceCount += 1
                case "[peer]":
                    section = "peer"
                    peerHasKey.append(false)
                default:
                    section = "other"
                    problems.append("Line \(number): unknown section \(trimmed).")
                }
                output.append(rawLine)
                continue
            }
            guard let equals = trimmed.firstIndex(of: "=") else {
                problems.append("Line \(number) is not 'Key = value'.")
                continue
            }
            let keyText = trimmed[..<equals].trimmingCharacters(in: spaceAndTab)
            let key = keyText.lowercased()
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: spaceAndTab)
            let items = value.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" }).map(String.init)

            switch section {
            case "interface":
                if let name = removedInterfaceKeys[key] {
                    removed.append(name)
                    if key == "dns" {
                        for item in items {
                            if ResolverPlan.isIPAddress(item) {
                                servers.append(item)
                            } else if ResolverPlan.isValidDomain(ResolverPlan.normalize(item)) {
                                domains.append(ResolverPlan.normalize(item))
                            } else {
                                ignored.append(item)
                            }
                        }
                    }
                    continue
                }
                guard interfaceKeys.contains(key) else {
                    problems.append("Line \(number): unknown [Interface] key '\(keyText)'.")
                    continue
                }
                if key == "privatekey", !value.isEmpty { hasPrivateKey = true }
                if key == "address" {
                    addresses += items.map { String($0.split(separator: "/").first ?? Substring($0)) }
                }
                if key == "table", value.lowercased() == "off" { tableOff = true }
            case "peer":
                guard peerKeys.contains(key) else {
                    problems.append("Line \(number): unknown [Peer] key '\(keyText)'.")
                    continue
                }
                if key == "publickey", !value.isEmpty, !peerHasKey.isEmpty { peerHasKey[peerHasKey.count - 1] = true }
                if key == "endpoint", !value.isEmpty { endpoints.append(value) }
                if key == "allowedips" {
                    if items.contains("0.0.0.0/0") { full4 = true }
                    if items.contains("::/0") { full6 = true }
                }
            default:
                problems.append("Line \(number) is outside [Interface] and [Peer].")
                continue
            }
            output.append(rawLine)
        }

        if interfaceCount != 1 { problems.append("The file needs exactly one [Interface] section.") }
        if interfaceCount >= 1, !hasPrivateKey { problems.append("[Interface] has no PrivateKey.") }
        if interfaceCount >= 1, addresses.isEmpty { problems.append("[Interface] has no Address.") }
        if peerHasKey.isEmpty { problems.append("No [Peer] section.") }
        if peerHasKey.contains(false) { problems.append("A [Peer] has no PublicKey.") }

        var sanitized = output.joined(separator: "\n")
        if !sanitized.hasSuffix("\n") { sanitized += "\n" }
        return WireGuardConfigReport(
            sanitized: sanitized,
            removed: removed,
            addresses: addresses,
            dnsServers: servers,
            dnsDomains: domains,
            ignoredDNS: ignored,
            endpoints: endpoints,
            fullTunnelIPv4: full4 && !tableOff,
            fullTunnelIPv6: full6 && !tableOff,
            problems: problems
        )
    }

    /// The file wg-quick runs as root: the sanitized text with the hook as PostUp
    /// and PreDown. wg-quick expands `%i` to the utun device and runs each hook
    /// with bash `eval`, so every value here is validated: the slug is [a-z0-9-],
    /// servers are IP addresses, domains are [a-z0-9.-].
    public static func rootConfig(_ report: WireGuardConfigReport, slug: String, routeStrategy: RouteStrategy) -> String {
        let servers = report.dnsServers.filter(ResolverPlan.isIPAddress).joined(separator: " ")
        let domains = report.dnsDomains.filter(ResolverPlan.isValidDomain).joined(separator: " ")
        let hooks = [
            "PostUp = NODENS_ROUTE_STRATEGY=\(routeStrategy.rawValue) NODENS_DNS_SERVERS='\(servers)' NODENS_DNS_DOMAINS='\(domains)' \(HookPaths.hook) wg-up \(slug) %i",
            "PreDown = \(HookPaths.hook) wg-down \(slug)",
        ]
        var lines = report.sanitized.components(separatedBy: "\n")
        if let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[interface]" }) {
            lines.insert(contentsOf: hooks, at: header + 1)
        }
        return lines.joined(separator: "\n")
    }
}
