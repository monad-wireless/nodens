import Foundation

/// Helpers for `osascript`, which Nodens uses only for the standard macOS
/// administrator prompt (`do shell script … with administrator privileges`).
public enum AppleScript {
    /// An AppleScript string literal, quotes included.
    public static func quote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// userCanceledErr: the user pressed Cancel in the admin prompt.
    public static func isUserCancelled(_ stderr: String) -> Bool { stderr.contains("-128") }
}
