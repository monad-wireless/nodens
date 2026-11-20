import Foundation
import NodensCore

/// The tailscale CLI. Every call has a hard timeout.
struct TailscaleClient: Sendable {
    let path: String?

    static func locate() -> TailscaleClient {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        return TailscaleClient(path: candidates.first { FileManager.default.isExecutableFile(atPath: $0) })
    }

    var isInstalled: Bool { path != nil }

    private func run(_ arguments: [String], timeout: TimeInterval = 8) async -> ProcessResult? {
        guard let path else { return nil }
        return await Shell.run(path, arguments, timeout: timeout)
    }

    func status() async -> TailscaleStatus? {
        guard let result = await run(["status", "--json", "--peers=false"]) else { return nil }
        return TailscaleParsing.parseStatus(result.stdout)
    }

    func profiles() async -> [TailscaleProfile]? {
        guard let result = await run(["switch", "--list"]), result.succeeded else { return nil }
        return TailscaleParsing.parseSwitchList(result.stdout)
    }

    /// The current profile's `--accept-dns` preference, or nil when it cannot be read.
    func acceptsDNS() async -> Bool? {
        guard let result = await run(["debug", "prefs"], timeout: 20), result.succeeded else { return nil }
        return TailscaleParsing.parseCorpDNS(prefsJSON: result.stdout)
    }

    func setAcceptDNS(_ enabled: Bool) async -> Bool {
        await run(["set", "--accept-dns=\(enabled)"])?.succeeded ?? false
    }

    func splitRoutes() async -> [SplitRoute] {
        guard let result = await run(["dns", "status"]), result.succeeded else { return [] }
        return TailscaleParsing.parseSplitRoutes(dnsStatus: result.stdout)
    }

    /// IPv4 addresses of the current tailnet's control server and relay servers,
    /// for the `host-routes` strategy. Resolved before the VPN is up.
    func infrastructureIPv4() async -> [String] {
        var names: [String] = []
        if let prefs = await run(["debug", "prefs"], timeout: 20), prefs.succeeded,
           let host = TailscaleParsing.controlHost(prefsJSON: prefs.stdout) {
            names.append(host)
        }
        if let map = await run(["debug", "derp-map"], timeout: 20), map.succeeded {
            names += TailscaleParsing.relayHosts(derpMapJSON: map.stdout)
        }
        var addresses: [String] = []
        for name in names {
            for address in await HostResolver.ipv4(name) where !addresses.contains(address) {
                addresses.append(address)
            }
        }
        return addresses
    }

    func up() async -> ProcessResult? { await run(["up"], timeout: 30) }
    func down() async -> ProcessResult? { await run(["down"], timeout: 15) }
    func switchTo(_ id: String) async -> ProcessResult? { await run(["switch", id], timeout: 30) }
}
