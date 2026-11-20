import Foundation

/// One file under /etc/resolver. See resolver(5).
public struct ResolverEntry: Sendable, Equatable {
    public let domain: String
    public let nameservers: [String]

    public init(domain: String, nameservers: [String]) {
        self.domain = domain
        self.nameservers = nameservers
    }

    public var fileContents: String {
        nameservers.map { "nameserver \($0)\n" }.joined() + "timeout 2\n"
    }
}

/// Which domains must keep resolving through the tailnet once Tailscale stops
/// being the default resolver (`tailscale set --accept-dns=false`).
///
/// Measured on Tailscale 1.102.2 with accept-dns off: 100.100.100.100 still
/// answers MagicDNS names and extra records, and answers SERVFAIL for split-DNS
/// domains. So the MagicDNS suffix and the extra-record domains go to
/// 100.100.100.100, and each split-DNS domain goes to its own resolver.
public enum ResolverPlan {
    public static let quad100 = "100.100.100.100"

    /// Top-level labels that never exist in public DNS. An extra record under any
    /// other top-level label is not routed, so a public zone is never hijacked.
    public static let privateTopLevelLabels: Set<String> = [
        "internal", "lan", "home", "corp", "intranet", "private", "test", "tailnet",
    ]

    public static func entries(
        magicDNSSuffix: String,
        extraRecordNames: [String],
        splitRoutes: [SplitRoute]
    ) -> [ResolverEntry] {
        var byDomain: [String: [String]] = [:]
        var quad100Domains: [String] = []

        let suffix = normalize(magicDNSSuffix)
        if isValidDomain(suffix) {
            byDomain[suffix] = [quad100]
            quad100Domains.append(suffix)
        }

        // Shortest parent first, so corp.internal absorbs b.corp.internal.
        let parents = Set(extraRecordNames.compactMap { privateParent(of: $0) })
        let ordered = parents.sorted { lhs, rhs in
            let l = labelCount(lhs)
            let r = labelCount(rhs)
            return l != r ? l < r : lhs < rhs
        }
        for parent in ordered where !isCovered(parent, by: quad100Domains) {
            byDomain[parent] = [quad100]
            quad100Domains.append(parent)
        }

        // A split route names its own resolver and wins over a broader domain.
        for route in splitRoutes {
            let domain = normalize(route.domain)
            let servers = route.resolvers.filter { isIPAddress($0) }
            guard isValidDomain(domain), !servers.isEmpty else { continue }
            byDomain[domain] = servers
        }

        return byDomain.keys.sorted().map { ResolverEntry(domain: $0, nameservers: byDomain[$0] ?? []) }
    }

    /// The input of `hook resolver-apply`: one "domain ns [ns…]" line per entry.
    public static func entriesFile(_ entries: [ResolverEntry]) -> String {
        entries
            .filter { isValidDomain($0.domain) && !$0.nameservers.isEmpty && $0.nameservers.allSatisfy(isIPAddress) }
            .map { ([$0.domain] + $0.nameservers).joined(separator: " ") + "\n" }
            .joined()
    }

    /// The parent domain of an extra record, when that parent is private.
    static func privateParent(of name: String) -> String? {
        let normalized = normalize(name)
        guard isValidDomain(normalized) else { return nil }
        let labels = normalized.split(separator: ".")
        guard labels.count >= 3, let last = labels.last, privateTopLevelLabels.contains(String(last)) else {
            return nil
        }
        return labels.dropFirst().joined(separator: ".")
    }

    public static func isCovered(_ domain: String, by domains: [String]) -> Bool {
        domains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    public static func normalize(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespaces).lowercased()
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }

    /// Two or more DNS labels of [a-z0-9-]. A single label is refused on purpose:
    /// a file for a whole top-level domain would capture far too much.
    public static func isValidDomain(_ domain: String) -> Bool {
        guard !domain.isEmpty, domain.count <= 253 else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        for label in labels {
            guard (1...63).contains(label.count),
                  label.allSatisfy({ allowed.contains($0) }),
                  label.first != "-",
                  label.last != "-"
            else { return false }
        }
        return true
    }

    public static func isIPAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return text.withCString { pointer in
            inet_pton(AF_INET, pointer, &v4) == 1 || inet_pton(AF_INET6, pointer, &v6) == 1
        }
    }

    static func labelCount(_ domain: String) -> Int {
        domain.split(separator: ".").count
    }
}
