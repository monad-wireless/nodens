import Foundation

/// One line from the OpenVPN management interface.
/// Reference: OpenVPN's doc/management-notes.txt.
public enum ManagementEvent: Sendable, Equatable {
    /// `>HOLD:`: openvpn waits for `hold release`.
    case hold
    /// `>PASSWORD:Need 'Auth' username/password`
    case needCredentials(realm: String)
    /// `>PASSWORD:Need 'Private Key' password` and other secrets Nodens does not hold.
    case needSecret(realm: String)
    /// `>PASSWORD:Verification Failed: 'Auth'`
    case authFailed(realm: String)
    /// `>STATE:…` push, or one record of the `state` command.
    case state(String)
    case success(String)
    case error(String)
    case info(String)
    case end
    case other(String)
}

public enum ManagementProtocol {
    public static func parse(_ rawLine: String) -> ManagementEvent {
        var line = rawLine
        // The management password prompt has no newline, so it prefixes the next line.
        while line.hasPrefix("ENTER PASSWORD:") { line.removeFirst("ENTER PASSWORD:".count) }

        if line.hasPrefix(">HOLD:") { return .hold }
        if line.hasPrefix(">PASSWORD:") {
            let body = String(line.dropFirst(">PASSWORD:".count))
            let realm = quoted(body) ?? ""
            if body.hasPrefix("Verification Failed") { return .authFailed(realm: realm) }
            if body.hasPrefix("Need ") {
                return body.contains("username/password") ? .needCredentials(realm: realm) : .needSecret(realm: realm)
            }
            return .other(line)
        }
        if line.hasPrefix(">STATE:") { return .state(stateName(String(line.dropFirst(">STATE:".count)))) }
        if line.hasPrefix(">INFO:") { return .info(String(line.dropFirst(">INFO:".count))) }
        if line.hasPrefix("SUCCESS:") { return .success(String(line.dropFirst("SUCCESS:".count)).trimmed) }
        if line.hasPrefix("ERROR:") { return .error(String(line.dropFirst("ERROR:".count)).trimmed) }
        if line == "END" { return .end }
        if let first = line.first, first.isNumber, line.contains(",") { return .state(stateName(line)) }
        return .other(line)
    }

    /// "1795105941,CONNECTED,SUCCESS,10.8.0.6,…" → "CONNECTED"
    public static func stateName(_ record: String) -> String {
        let fields = record.split(separator: ",", omittingEmptySubsequences: false)
        return fields.count > 1 ? String(fields[1]) : ""
    }

    /// A double-quoted management argument with `\` and `"` escaped.
    public static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// The two commands that answer `>PASSWORD:Need '<realm>' username/password`.
    /// nil when a value contains a line break, which the line protocol cannot carry.
    public static func credentialCommands(realm: String, username: String, password: String) -> [String]? {
        let values = [realm, username, password]
        guard !values.contains(where: { $0.contains("\n") || $0.contains("\r") }) else { return nil }
        return [
            "username \(quote(realm)) \(quote(username))",
            "password \(quote(realm)) \(quote(password))",
        ]
    }

    private static func quoted(_ text: String) -> String? {
        guard let start = text.firstIndex(of: "'") else { return nil }
        let rest = text[text.index(after: start)...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }
}
