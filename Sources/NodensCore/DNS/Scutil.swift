import Foundation

/// Reads `scutil --dns`.
public enum Scutil {
    /// Name servers of resolver #1 in the unscoped section, which is the
    /// resolver macOS uses for every name that no other resolver claims.
    public static func defaultResolverNameservers(_ output: String) -> [String] {
        var servers: [String] = []
        var inFirst = false
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("DNS configuration (for scoped queries)") { break }
            if line.hasPrefix("resolver #") {
                if inFirst { break }
                inFirst = (line == "resolver #1")
                continue
            }
            guard inFirst, line.hasPrefix("nameserver["), let separator = line.range(of: " : ") else { continue }
            servers.append(String(line[separator.upperBound...]).trimmed)
        }
        return servers
    }

    /// True while Tailscale's 100.100.100.100 is the default resolver.
    public static func tailscaleHoldsDefault(_ output: String) -> Bool {
        defaultResolverNameservers(output).contains(ResolverPlan.quad100)
    }
}
