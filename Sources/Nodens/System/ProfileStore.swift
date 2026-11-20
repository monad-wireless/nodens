import Foundation
import NodensCore

/// Profiles and per-tunnel run files under ~/Library/Application Support/Nodens
/// (mode 700). The configurations hold keys, so every file is mode 600.
enum ProfileStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Nodens", isDirectory: true)
    }

    static var runDirectory: URL { directory.appendingPathComponent("run", isDirectory: true) }
    static var file: URL { directory.appendingPathComponent("profiles.json") }

    static func ensureDirectories() {
        for url in [directory, runDirectory] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
    }

    static func load() -> [VPNProfile] {
        guard let data = try? Data(contentsOf: file),
              let profiles = try? JSONDecoder().decode([VPNProfile].self, from: data)
        else { return [] }
        return profiles
    }

    static func save(_ profiles: [VPNProfile]) throws {
        ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Writes a private file (mode 600).
    static func writePrivate(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The .ovpn inside every Tunnelblick configuration this user can read.
    static func tunnelblickConfigs() -> [(name: String, config: String)] {
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Tunnelblick/Configurations").path,
            "/Library/Application Support/Tunnelblick/Shared",
        ]
        var found: [(String, String)] = []
        for root in roots {
            let bundles = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for bundle in bundles.sorted() where bundle.hasSuffix(".tblk") {
                let resources = "\(root)/\(bundle)/Contents/Resources"
                let files = (try? FileManager.default.contentsOfDirectory(atPath: resources)) ?? []
                guard let ovpn = files.sorted().first(where: { $0.hasSuffix(".ovpn") || $0.hasSuffix(".conf") }),
                      let text = try? String(contentsOfFile: "\(resources)/\(ovpn)", encoding: .utf8)
                else { continue }
                found.append((String(bundle.dropLast(5)), text))
            }
        }
        return found
    }
}
