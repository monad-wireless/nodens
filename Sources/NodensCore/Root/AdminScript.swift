import Foundation

/// How the root hook keeps Tailscale's own traffic routable while a VPN takes
/// all IPv4 traffic (`0/1` and `128/1` through the tunnel).
///
/// Tailscale binds its outer traffic to the physical interface. Under such a
/// full tunnel, a socket bound to Wi-Fi was measured to get "No route to host"
/// for Internet addresses. Which of these routes repairs that best can differ
/// per Mac, so the strategy is a setting. See docs/TAILSCALE.md.
public enum RouteStrategy: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Host routes via the uplink gateway for the tailnet's control and relay servers.
    case hostRoutes = "host-routes"
    /// A default route scoped to the uplink interface.
    case scopedDefault = "scoped-default"
    /// `0/1` and `128/1` scoped to the uplink interface.
    case scopedHalves = "scoped-halves"
    /// No extra routes.
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .hostRoutes: return "Host routes to the tailnet's control and relay servers"
        case .scopedDefault: return "Scoped default route on the uplink"
        case .scopedHalves: return "Scoped 0/1 and 128/1 on the uplink"
        case .off: return "Off"
        }
    }
}

/// Root-side locations. None contains a space, because openvpn splits its
/// script commands on spaces.
public enum HookPaths {
    public static let libexec = "/usr/local/libexec/nodens"
    public static let hook = "\(libexec)/hook"
    public static let etc = "/usr/local/etc/nodens"
    /// wg-quick takes the interface name from the file name: <slug>.conf.
    public static let wgDir = "\(etc)/wg"
    /// Persistent records of every change the hook made. Survives a reboot on
    /// purpose: the IPv6 setting and /etc/resolver files survive one too.
    public static let state = "/usr/local/var/nodens"
    public static let tunnels = "\(state)/tunnels"
    public static let resolverRegistry = "\(state)/resolver"
    public static let logs = "/Library/Logs/Nodens"

    public static func config(_ slug: String) -> String { "\(etc)/\(slug).ovpn" }
    public static func wgConfig(_ slug: String) -> String { "\(wgDir)/\(slug).conf" }
    public static func hosts(_ slug: String) -> String { "\(etc)/\(slug).hosts" }
    public static func pid(_ slug: String) -> String { "\(state)/\(slug).pid" }
    public static func log(_ slug: String) -> String { "\(logs)/\(slug).log" }
    public static func launchLog(_ slug: String) -> String { "\(logs)/\(slug).launch.log" }
}

/// What every connect installs besides the engine's own configuration.
public struct RootSetup: Sendable, Equatable {
    public var slug: String
    public var hookSource: String
    /// IPv4 addresses for `host-routes`, one per line. nil: none.
    public var stagedHosts: String?
    /// Tailnet resolver entries ("domain ns…" per line). nil: leave /etc/resolver alone.
    public var stagedTailnetEntries: String?

    public init(slug: String, hookSource: String, stagedHosts: String?, stagedTailnetEntries: String?) {
        self.slug = slug
        self.hookSource = hookSource
        self.stagedHosts = stagedHosts
        self.stagedTailnetEntries = stagedTailnetEntries
    }
}

/// One OpenVPN connect.
public struct OpenVPNLaunch: Sendable, Equatable {
    public var setup: RootSetup
    public var openvpn: String
    public var stagedConfig: String
    public var managementPort: Int
    public var managementPasswordFile: String
    public var routeStrategy: RouteStrategy

    public init(
        setup: RootSetup, openvpn: String, stagedConfig: String,
        managementPort: Int, managementPasswordFile: String, routeStrategy: RouteStrategy
    ) {
        self.setup = setup
        self.openvpn = openvpn
        self.stagedConfig = stagedConfig
        self.managementPort = managementPort
        self.managementPasswordFile = managementPasswordFile
        self.routeStrategy = routeStrategy
    }
}

/// One WireGuard connect.
public struct WireGuardLaunch: Sendable, Equatable {
    public var setup: RootSetup
    public var wgQuick: String
    /// The output of `WireGuardConfig.rootConfig`.
    public var stagedConfig: String

    public init(setup: RootSetup, wgQuick: String, stagedConfig: String) {
        self.setup = setup
        self.wgQuick = wgQuick
        self.stagedConfig = stagedConfig
    }
}

/// Shell commands that run as root through one admin prompt.
public enum AdminScript {
    /// wg-quick needs bash 4+ (Homebrew's) and finds wireguard-go and wg on PATH.
    public static let toolPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Installs the hook from the app bundle and creates its directories.
    public static func prelude(hookSource: String) -> [String] {
        [
            "umask 022",
            "/bin/mkdir -p \(HookPaths.libexec) \(HookPaths.etc) \(HookPaths.wgDir) \(HookPaths.tunnels) \(HookPaths.resolverRegistry) \(HookPaths.logs)",
            "/bin/chmod 0700 \(HookPaths.etc) \(HookPaths.wgDir)",
            "/usr/bin/install -m 0755 -o root -g wheel \(quote(hookSource)) \(HookPaths.hook)",
        ]
    }

    /// The steps every connect shares: undo stale tunnels, write the tailnet's
    /// resolver files, install the host list, prepare the log.
    static func commonSetup(_ setup: RootSetup) -> [String] {
        var lines = prelude(hookSource: setup.hookSource)
        lines.append("\(HookPaths.hook) cleanup-stale")
        if let entries = setup.stagedTailnetEntries {
            lines.append("\(HookPaths.hook) resolver-apply tailnet \(quote(entries))")
        }
        if let hosts = setup.stagedHosts {
            lines.append("/usr/bin/install -m 0644 -o root -g wheel \(quote(hosts)) \(HookPaths.hosts(setup.slug))")
        } else {
            lines.append("/bin/rm -f \(HookPaths.hosts(setup.slug))")
        }
        lines.append("/usr/bin/touch \(HookPaths.log(setup.slug))")
        lines.append("/bin/chmod 0644 \(HookPaths.log(setup.slug))")
        return lines
    }

    // MARK: OpenVPN

    /// Nodens' options come after `--config`, so they override anything left in the file.
    public static func openvpnArguments(_ launch: OpenVPNLaunch) -> [String] {
        let slug = launch.setup.slug
        return [
            "--config", HookPaths.config(slug),
            "--daemon", "nodens-\(slug)",
            "--log", HookPaths.log(slug),
            "--writepid", HookPaths.pid(slug),
            "--management", "127.0.0.1", String(launch.managementPort), launch.managementPasswordFile,
            "--management-hold",
            "--management-query-passwords",
            "--auth-retry", "interact",
            "--script-security", "2",
            "--route-up", "\(HookPaths.hook) ovpn-up",
            "--route-pre-down", "\(HookPaths.hook) ovpn-down",
            "--dns-updown", "disable",
            "--setenv", "NODENS_SLUG", slug,
            "--setenv", "NODENS_ROUTE_STRATEGY", launch.routeStrategy.rawValue,
        ]
    }

    public static func openvpnConnect(_ launch: OpenVPNLaunch) -> String {
        let slug = launch.setup.slug
        var lines = commonSetup(launch.setup)
        lines.append("/usr/bin/install -m 0600 -o root -g wheel \(quote(launch.stagedConfig)) \(HookPaths.config(slug))")
        // All three streams redirected: `do shell script` waits for every child
        // that still holds one, and openvpn --daemon keeps running.
        let command = ([quote(launch.openvpn)] + openvpnArguments(launch).map(quote)).joined(separator: " ")
        lines.append("\(command) </dev/null >\(HookPaths.launchLog(slug)) 2>&1")
        return lines.joined(separator: " && ")
    }

    /// Stops an openvpn the management interface cannot reach. Its own
    /// route-pre-down hook undoes its changes; cleanup catches the rest.
    public static func openvpnKill(slug: String, hookSource: String) -> String {
        var lines = prelude(hookSource: hookSource)
        let pid = HookPaths.pid(slug)
        lines.append("{ [ ! -r \(pid) ] || /bin/kill -TERM \"$(/bin/cat \(pid))\" || true; }")
        lines.append("/bin/sleep 2")
        lines.append("\(HookPaths.hook) cleanup-stale")
        return lines.joined(separator: " && ")
    }

    // MARK: WireGuard

    public static func wireguardUp(_ launch: WireGuardLaunch) -> String {
        let slug = launch.setup.slug
        var lines = commonSetup(launch.setup)
        lines.append("/usr/bin/install -m 0600 -o root -g wheel \(quote(launch.stagedConfig)) \(HookPaths.wgConfig(slug))")
        // wg-quick leaves a route monitor running; all three streams go to the log.
        lines.append("/usr/bin/env PATH=\(toolPath) \(quote(launch.wgQuick)) up \(HookPaths.wgConfig(slug)) </dev/null >>\(HookPaths.log(slug)) 2>&1")
        return lines.joined(separator: " && ")
    }

    /// `wg-quick down` runs the hook's wg-down step (PreDown). A failed down
    /// (interface already gone) still ends with a cleanup of stale records.
    public static func wireguardDown(wgQuick: String, slug: String, hookSource: String) -> String {
        var lines = prelude(hookSource: hookSource)
        lines.append("{ /usr/bin/env PATH=\(toolPath) \(quote(wgQuick)) down \(HookPaths.wgConfig(slug)) </dev/null >>\(HookPaths.log(slug)) 2>&1 || true; }")
        lines.append("\(HookPaths.hook) cleanup-stale")
        return lines.joined(separator: " && ")
    }

    // MARK: Maintenance

    public static func cleanup(hookSource: String) -> String {
        (prelude(hookSource: hookSource) + ["\(HookPaths.hook) cleanup-stale"]).joined(separator: " && ")
    }

    public static func clearTailnetResolvers(hookSource: String) -> String {
        (prelude(hookSource: hookSource) + ["\(HookPaths.hook) resolver-clear tailnet"]).joined(separator: " && ")
    }
}
