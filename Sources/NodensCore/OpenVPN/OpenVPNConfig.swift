import Foundation

/// The result of checking a pasted .ovpn file.
public struct OpenVPNConfigReport: Sendable, Equatable {
    /// The text openvpn runs as root: every directive that could run or redirect
    /// anything is removed, `auth-user-pass` loses its file argument.
    public let sanitized: String
    /// Directives Nodens removed, in file order.
    public let removed: [String]
    /// The server expects a username and password.
    public let needsCredentials: Bool
    /// `host [port]` of every `remote` line.
    public let remotes: [String]
    /// Reasons the file cannot run. Empty means usable.
    public let problems: [String]

    public var isUsable: Bool { problems.isEmpty }
}

/// openvpn reads the file as root with `--script-security 2`. Its tokenizer
/// accepts quotes and backslash escapes in every token and splits on any ASCII
/// whitespace, so the check fails closed: a control character, a quoted or
/// escaped option name, or an unknown inline block makes the file unusable.
public enum OpenVPNConfig {
    /// Directives Nodens owns or that would run code, write files or change
    /// identity as root. Nodens adds its own versions after `--config`.
    public static let removedDirectives: Set<String> = [
        // scripts and plugins
        "up", "down", "route-up", "route-pre-down", "ipchange", "tls-verify", "client-connect",
        "client-disconnect", "learn-address", "auth-user-pass-verify", "plugin", "script-security",
        "dns-updown", "setenv", "setenv-safe", "iproute",
        // management interface
        "management", "management-client", "management-hold", "management-query-passwords",
        "management-query-proxy", "management-query-remote", "management-client-user",
        "management-client-group", "management-client-auth", "management-signal",
        "management-forget-disconnect", "management-up-down", "management-log-cache",
        "management-external-key", "management-external-cert",
        // process, files and identity
        "daemon", "log", "log-append", "syslog", "writepid", "status", "user", "group", "chroot",
        "cd", "config", "tmp-dir", "askpass", "auth-retry", "route-noexec", "ifconfig-noexec",
        "replay-persist", "tls-export-cert",
        // code loaded into openvpn
        "providers", "engine", "pkcs11-providers",
    ]

    /// Directives whose argument is a file unless the material is inline.
    static let fileDirectives: Set<String> = [
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "pkcs12", "dh",
        "extra-certs", "crl-verify", "secret",
    ]

    /// Inline blocks that carry key or certificate material and nothing else.
    static let inlineTags: Set<String> = [
        "ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "pkcs12", "dh",
        "extra-certs", "crl-verify", "secret", "peer-fingerprint",
    ]

    static func hasControlCharacter(_ line: String) -> Bool {
        line.unicodeScalars.contains { ($0.value < 0x20 && $0 != "\t") || $0.value == 0x7F }
    }

    /// An option name of plain ASCII letters, digits and dashes.
    static func isPlainOptionName(_ name: Substring) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    public static func check(_ text: String) -> OpenVPNConfigReport {
        var output: [String] = []
        var removed: [String] = []
        var needsCredentials = false
        var remotes: [String] = []
        var problems: [String] = []
        var openBlock: String?
        var keepBlock = true

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let number = index + 1
            if hasControlCharacter(rawLine) {
                problems.append("Line \(number) contains a control character.")
                continue
            }
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))

            // Inline material (<ca>…</ca>) passes through untouched. openvpn ends a
            // block at any line that starts with the closing tag, so inside a block
            // a line starting with "<" must be exactly that tag.
            if let tag = openBlock {
                if line.hasPrefix("<"), line.lowercased() != "</\(tag)>" {
                    problems.append("Line \(number): only </\(tag)> may start with '<' inside <\(tag)>.")
                    continue
                }
                if keepBlock { output.append(rawLine) }
                if line.lowercased() == "</\(tag)>" { openBlock = nil }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</"), line.count > 2 {
                let tag = String(line.dropFirst().dropLast()).lowercased()
                openBlock = tag
                keepBlock = inlineTags.contains(tag)
                if keepBlock {
                    output.append(rawLine)
                } else {
                    problems.append("Line \(number): the inline block <\(tag)> is not accepted; only key and certificate blocks are.")
                }
                continue
            }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") {
                output.append(rawLine)
                continue
            }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            var name = tokens[0]
            if name.hasPrefix("--") { name = name.dropFirst(2) }
            guard isPlainOptionName(name) else {
                problems.append("Line \(number): the option name '\(tokens[0])' contains quotes, escapes or other characters openvpn would reinterpret.")
                continue
            }
            let directive = name.lowercased()

            if removedDirectives.contains(directive) {
                removed.append(directive)
                continue
            }
            switch directive {
            case "auth-user-pass":
                needsCredentials = true
                if tokens.count > 1 { removed.append("auth-user-pass file") }
                output.append("auth-user-pass")
            case "remote":
                if tokens.count > 1 { remotes.append(tokens[1...].prefix(2).joined(separator: " ")) }
                output.append(rawLine)
            default:
                if fileDirectives.contains(directive), tokens.count > 1, tokens[1] != "[inline]" {
                    problems.append("'\(directive)' points to the file \(tokens[1]). Paste its content inline as <\(directive)>…</\(directive)>.")
                }
                output.append(rawLine)
            }
        }

        if let tag = openBlock { problems.append("The inline block <\(tag)> has no closing </\(tag)>.") }
        if remotes.isEmpty { problems.append("No 'remote' line: the server is unknown.") }

        var sanitized = output.joined(separator: "\n")
        if !sanitized.hasSuffix("\n") { sanitized += "\n" }
        return OpenVPNConfigReport(
            sanitized: sanitized,
            removed: removed,
            needsCredentials: needsCredentials,
            remotes: remotes,
            problems: problems
        )
    }
}
