# Architecture

Nodens is a SwiftPM package with four targets and one shell script.

```text
Sources/
  NodensCore/        pure logic, no AppKit, unit-tested
    Model/           VPNProfile, TunnelState, StatusGlyph
    OpenVPN/         OpenVPNConfig (sanitizer), Management (protocol)
    WireGuard/       WireGuardConfig (sanitizer, root config)
    Tailscale/       TailscaleParsing (CLI output)
    DNS/             ResolverPlan (/etc/resolver), Scutil
    Policy/          RestorePolicy, AttachPolicy
    Root/            AdminScript (root commands), HookPaths, AppleScript
    System/          Shell (processes with a hard deadline)
  NodensArt/         CoreGraphics drawing: app icon, menu-bar glyph, README tiles
  Nodens/            the app
    App/             NodensApp (entry point), AppModel (state and actions)
    Drivers/         TunnelDriver protocol, OpenVPN and WireGuard drivers,
                     ManagementSession, Staging
    Tailscale/       TailscaleClient (CLI), TailscaleCoexistence (DNS)
    System/          Admin (admin prompt), HookState, Keychain, ProfileStore, probes
    UI/              menu, settings window, profile editor
  RenderArt/         `make art`
Resources/
  nodens-hook        the root hook (POSIX sh)
  Info.plist, AppIcon.icns
```

The rule of the split: anything that can be decided without the system lives
in `NodensCore` and has tests. The app target only runs processes, talks to
sockets, and draws.

## Drivers

Every VPN engine sits behind one protocol:

```swift
@MainActor
protocol TunnelDriver: AnyObject {
    var kind: DriverKind { get }
    var connectTimeout: Int { get }
    func rawState(_ profile: VPNProfile) -> String?
    func connect(_ profile: VPNProfile, plan: ConnectPlan, beforeTraffic: () async -> Bool) async -> String?
    func disconnect(_ profile: VPNProfile, plan: ConnectPlan) async -> String?
    func poll(_ profiles: [VPNProfile]) async
}
```

- `rawState` uses OpenVPN's management vocabulary for every engine: `EXITING`
  idle, `CONNECTED` up, anything else in between. `nil` means "an engine seems
  to run, but the driver cannot reach it". The policies treat that as unknown.
- `beforeTraffic` runs once the root side is ready and before the tunnel
  carries traffic. The app uses it to take Tailscale out of the default DNS
  slot. Returning false stops the connect.
- `ConnectPlan` carries the engine paths, the hook, the route strategy, the
  tailnet's relay addresses and the tailnet resolver entries.

A new engine is one new conforming class, one `DriverKind` case, a sanitizer
in `NodensCore`, and the root commands in `AdminScript`.

### OpenVPN

1. `OpenVPNConfig.check` sanitizes the pasted file.
2. One admin prompt runs `AdminScript.openvpnConnect`:
   - it installs the hook;
   - it undoes stale tunnels;
   - it writes the tailnet's resolver files;
   - it installs the config (root, mode 600);
   - it starts `openvpn --daemon`. Nodens' own options follow `--config` and
     override the file: `--management 127.0.0.1 <port> <password file>`,
     `--management-hold`, `--management-query-passwords`,
     `--auth-retry interact`, `--script-security 2`, `--route-up` and
     `--route-pre-down` (the hook), `--dns-updown disable`.
3. `ManagementSession` connects to the port and answers the password prompt.
   It sends `state on`, `hold off`, and, after `beforeTraffic`, `hold release`.
4. On `>PASSWORD:Need 'Auth'`, the driver answers from the Keychain. This also
   happens after every reconnect, because servers may use `auth-nocache`. A
   rejected login stops the tunnel instead of retrying it.
5. Disconnect sends `signal SIGTERM` over the port: no admin prompt.

If the app restarts, `AttachPolicy` decides whether to attach to a running
openvpn again or forget its run files. A connect in flight is never touched,
because its run file exists before openvpn does.

### WireGuard

1. `WireGuardConfig.check` sanitizes the pasted file. It is an allow-list:
   only known `[Interface]` and `[Peer]` keys pass. `DNS`, `PreUp`, `PostUp`,
   `PreDown`, `PostDown` and `SaveConfig` are removed.
2. `WireGuardConfig.rootConfig` adds the hook as `PostUp` and `PreDown`.
   wg-quick expands `%i` to the utun device.
3. `beforeTraffic` runs, then one admin prompt runs `AdminScript.wireguardUp`:
   the same shared setup, then `wg-quick up` with Homebrew's tools on `PATH`.
4. The state is "CONNECTED" while a utun interface carries one of the
   profile's addresses (`getifaddrs`, no root needed).
5. Disconnect runs `wg-quick down` through one admin prompt.

## The root hook

`Resources/nodens-hook` is the only code Nodens runs as root apart from the
engines. Every admin command installs it to `/usr/local/libexec/nodens/hook`.

| Command | Caller | Does |
|---|---|---|
| `ovpn-up` / `ovpn-down` | openvpn `--route-up` / `--route-pre-down` | tunnel up / undo |
| `wg-up <slug> <utun>` / `wg-down <slug>` | wg-quick `PostUp` / `PreDown` | tunnel up / undo |
| `cleanup-stale` | every admin command | undo tunnels whose engine is gone |
| `resolver-apply` / `resolver-clear` | connect, settings | tailnet resolver files |

On tunnel up the hook:

1. records the tunnel device and kind;
2. if the tunnel holds `0/1` (a full tunnel):
   - it applies the route strategy (see [TAILSCALE.md](TAILSCALE.md));
   - unless IPv6 also goes through the tunnel, it turns IPv6 off on the
     uplink's network service;
3. writes `/etc/resolver/<domain>` for the VPN's own domains (pushed
   `dhcp-option DOMAIN`, or the WireGuard `DNS` line).

Every change is recorded under `/usr/local/var/nodens/tunnels/<slug>/`. Undo
reverses exactly the recorded changes and deletes the root copy of the
configuration. The records persist across reboots on purpose: the IPv6
setting and the resolver files persist too.

The hook is the only writer of the resolver files Nodens needs. A registry
(`/usr/local/var/nodens/resolver/<domain>`) names each file's owner
(`tailnet` or `tunnel:<slug>`). A file the hook did not write is never touched.

Every hook command has a dry-run mode (`NODENS_DRY_RUN=1`). It prints route
and `networksetup` commands instead of running them. `make check-hook` runs
both tunnel paths that way against the real routing table.

## Tailscale coexistence

`TailscaleCoexistence` prepares a connect (status, relay addresses, resolver
entries), takes Tailscale out of the default DNS slot, and restores it.

`RestorePolicy` allows the restore only on positive evidence:

- no action in flight;
- a fresh read of every tunnel, all idle;
- no unknown `openvpn` or `wireguard-go` process;
- the current Tailscale profile is one Nodens changed.

A failed or stale read never counts as "all idle".

## The app model

`AppModel` holds the state behind the menu and the settings window.

- Two independent polls run every 3 s, one for Tailscale and one for the
  tunnels. A stuck engine cannot freeze the Tailscale rows.
- One action runs at a time (`exclusive`). The restore rule reads both
  `operationInFlight` and an action counter, so a read that started before an
  action ended is discarded.
- Every external call has a hard timeout (`Shell.run`). A hung CLI or engine
  never hangs the menu.

## Files

| Path | Owner | Content |
|---|---|---|
| `~/Library/Application Support/Nodens/profiles.json` | user, 600 | profiles (configurations included) |
| `~/Library/Application Support/Nodens/run/` | user, 700 | management port and password per running OpenVPN tunnel |
| Keychain, service `io.github.monad-wireless.nodens.openvpn` | user | OpenVPN passwords |
| `/usr/local/libexec/nodens/hook` | root | the hook |
| `/usr/local/etc/nodens/` | root, 700 | configurations while connected, relay host lists |
| `/usr/local/var/nodens/` | root | change records, resolver registry, pid files |
| `/Library/Logs/Nodens/` | root, readable | engine and hook logs |
| `/etc/resolver/<domain>` | root | resolver files, owned by the hook |
