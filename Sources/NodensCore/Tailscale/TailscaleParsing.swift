import Foundation

/// The parts of `tailscale status --json` Nodens uses.
public struct TailscaleStatus: Sendable, Equatable {
    public let backendState: String
    public let tailscaleIPs: [String]
    /// MagicDNS suffix of the current tailnet, without a trailing dot. Empty when unknown.
    public let magicDNSSuffix: String
    public let tailnetName: String?
    /// This Mac's MagicDNS name, without a trailing dot.
    public let selfDNSName: String?
    /// Names of the control server's extra DNS records (for example Headscale's `extra_records`).
    public let extraRecordNames: [String]

    public var isRunning: Bool { backendState == "Running" }
}

/// One row of `tailscale switch --list`.
public struct TailscaleProfile: Sendable, Equatable, Identifiable {
    public let id: String
    public let tailnet: String
    public let account: String
    public let isCurrent: Bool
}

/// One split-DNS route from `tailscale dns status`.
public struct SplitRoute: Sendable, Equatable {
    public let domain: String
    public let resolvers: [String]
}

/// Parsers for the Tailscale CLI. The formats are pinned by tests against
/// Tailscale 1.102.
public enum TailscaleParsing {
    private struct RawStatus: Decodable {
        struct Tailnet: Decodable {
            let Name: String?
            let MagicDNSSuffix: String?
        }

        struct Node: Decodable {
            let DNSName: String?
        }

        struct Record: Decodable {
            let Name: String
        }

        let BackendState: String
        let TailscaleIPs: [String]?
        let MagicDNSSuffix: String?
        let CurrentTailnet: Tailnet?
        let ExtraRecords: [Record]?
        let selfNode: Node?

        enum CodingKeys: String, CodingKey {
            case BackendState, TailscaleIPs, MagicDNSSuffix, CurrentTailnet, ExtraRecords
            case selfNode = "Self"
        }
    }

    public static func parseStatus(_ json: String) -> TailscaleStatus? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawStatus.self, from: data)
        else { return nil }
        let suffix = raw.CurrentTailnet?.MagicDNSSuffix ?? raw.MagicDNSSuffix ?? ""
        return TailscaleStatus(
            backendState: raw.BackendState,
            tailscaleIPs: raw.TailscaleIPs ?? [],
            magicDNSSuffix: trimDot(suffix),
            tailnetName: raw.CurrentTailnet?.Name,
            selfDNSName: raw.selfNode?.DNSName.map(trimDot).flatMap { $0.isEmpty ? nil : $0 },
            extraRecordNames: (raw.ExtraRecords ?? []).map(\.Name)
        )
    }

    /// Parses the table printed by `tailscale switch --list`. The current profile's
    /// account carries a trailing `*`.
    public static func parseSwitchList(_ text: String) -> [TailscaleProfile] {
        var profiles: [TailscaleProfile] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3, fields[0] != "ID" else { continue }
            var account = fields[2...].joined(separator: " ")
            let isCurrent = account.hasSuffix("*")
            if isCurrent { account.removeLast() }
            profiles.append(TailscaleProfile(id: fields[0], tailnet: fields[1], account: account, isCurrent: isCurrent))
        }
        return profiles
    }

    /// Reads `CorpDNS` (the `--accept-dns` preference) from `tailscale debug prefs`.
    public static func parseCorpDNS(prefsJSON: String) -> Bool? {
        struct Prefs: Decodable {
            let CorpDNS: Bool?
        }
        guard let data = prefsJSON.data(using: .utf8),
              let prefs = try? JSONDecoder().decode(Prefs.self, from: data)
        else { return nil }
        return prefs.CorpDNS
    }

    /// Reads the "Split DNS Routes:" section of `tailscale dns status`.
    /// Tailscale marks that output as preliminary, so the tests pin its shape.
    public static func parseSplitRoutes(dnsStatus: String) -> [SplitRoute] {
        var routes: [SplitRoute] = []
        var inSection = false
        for rawLine in dnsStatus.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "Split DNS Routes:" {
                inSection = true
                continue
            }
            guard inSection else { continue }
            if line.isEmpty { break }
            guard line.hasPrefix("- ") else { continue }
            let parts = String(line.dropFirst(2)).components(separatedBy: "->")
            guard parts.count == 2 else { continue }
            let domain = trimDot(parts[0].trimmingCharacters(in: .whitespaces))
            let resolvers = parts[1]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            routes.append(SplitRoute(domain: domain, resolvers: resolvers))
        }
        return routes
    }

    /// Host of `ControlURL` in `tailscale debug prefs`.
    public static func controlHost(prefsJSON: String) -> String? {
        struct Prefs: Decodable {
            let ControlURL: String?
        }
        guard let data = prefsJSON.data(using: .utf8),
              let prefs = try? JSONDecoder().decode(Prefs.self, from: data),
              let url = prefs.ControlURL.flatMap(URL.init(string:)),
              let host = url.host, !host.isEmpty
        else { return nil }
        return host
    }

    /// Relay (DERP) servers in `tailscale debug derp-map`: the IPv4 literal when
    /// the map gives one, else the host name.
    public static func relayHosts(derpMapJSON: String) -> [String] {
        struct Node: Decodable {
            let HostName: String?
            let IPv4: String?
        }
        struct Region: Decodable {
            let Nodes: [Node]?
        }
        struct DERPMap: Decodable {
            let Regions: [String: Region]?
        }
        guard let data = derpMapJSON.data(using: .utf8),
              let map = try? JSONDecoder().decode(DERPMap.self, from: data)
        else { return [] }
        var hosts: [String] = []
        for key in (map.Regions ?? [:]).keys.sorted() {
            for node in map.Regions?[key]?.Nodes ?? [] {
                if let ipv4 = node.IPv4, !ipv4.isEmpty, ipv4 != "none" {
                    hosts.append(ipv4)
                } else if let name = node.HostName, !name.isEmpty {
                    hosts.append(name)
                }
            }
        }
        return hosts
    }

    static func trimDot(_ name: String) -> String {
        var result = name
        while result.hasSuffix(".") { result.removeLast() }
        return result
    }
}
