import Foundation
import NodensCore

/// Root commands through the standard macOS administrator prompt.
enum Admin {
    enum Outcome: Equatable {
        case done
        case cancelled
        case failed(String)
    }

    static func run(_ command: String, prompt: String) async -> Outcome {
        let script = "do shell script \(AppleScript.quote(command)) with prompt \(AppleScript.quote(prompt)) with administrator privileges"
        let result = await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 300)
        if result.succeeded { return .done }
        if AppleScript.isUserCancelled(result.stderr) { return .cancelled }
        return .failed(result.timedOut ? "the admin prompt timed out" : result.stderr.trimmed)
    }

    /// The hook inside the app bundle, which every admin command installs.
    static var hookSource: String? {
        Bundle.main.url(forResource: "nodens-hook", withExtension: nil)?.path
    }
}

/// Read-only view of the hook's records (the directories are world-readable).
enum HookState {
    /// Domains in /etc/resolver that the hook wrote for the tailnet.
    static func tailnetDomains() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: HookPaths.resolverRegistry)) ?? []
        return names.filter { name in
            (try? String(contentsOfFile: "\(HookPaths.resolverRegistry)/\(name)", encoding: .utf8))?.trimmed == "tailnet"
        }.sorted()
    }

    /// Tunnels with recorded changes whose engine no longer runs.
    static func staleTunnels() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: HookPaths.tunnels)) ?? []
        return names.filter { !tunnelAlive($0) }.sorted()
    }

    /// The engine of a recorded tunnel still runs. A WireGuard record names its
    /// utun device; openvpn has a pid file.
    static func tunnelAlive(_ slug: String) -> Bool {
        let directory = "\(HookPaths.tunnels)/\(slug)"
        let kind = (try? String(contentsOfFile: "\(directory)/kind", encoding: .utf8))?.trimmed
        if kind == "wg" {
            guard let device = (try? String(contentsOfFile: "\(directory)/device", encoding: .utf8))?.trimmed,
                  !device.isEmpty
            else { return false }
            return if_nametoindex(device) != 0
        }
        return openvpnAlive(slug)
    }

    /// An openvpn started for `slug` still runs. A root process answers kill(0)
    /// with EPERM, which also means "exists".
    static func openvpnAlive(_ slug: String) -> Bool {
        guard let text = try? String(contentsOfFile: HookPaths.pid(slug), encoding: .utf8),
              let pid = Int32(text.trimmed), pid > 0
        else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// An openvpn or wireguard-go process runs. nil when pgrep does not answer.
    static func anyVPNProcess() async -> Bool? {
        let openvpn = await anyProcess("openvpn")
        let wireguard = await anyProcess("wireguard-go")
        if openvpn == true || wireguard == true { return true }
        if openvpn == nil || wireguard == nil { return nil }
        return false
    }

    private static func anyProcess(_ name: String) async -> Bool? {
        let result = await Shell.run("/usr/bin/pgrep", ["-x", name], timeout: 5)
        guard !result.timedOut else { return nil }
        switch result.status {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// The last lines of a root-written, world-readable log.
    static func tail(_ path: String, lines: Int = 4) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: " | ")
    }
}
