# Security policy

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's
private reporting instead: **Security → Report a vulnerability** on
[github.com/monad-wireless/nodens](https://github.com/monad-wireless/nodens/security/advisories/new).

Include the version or commit, the steps to reproduce, and what an attacker
gains. Fixes are released before the details are published.

## Supported versions

Nodens is pre-release. Only the latest commit on the default branch receives
fixes.

## Threat model

Nodens starts programs as root, so it is security-sensitive by design.

### What runs as root

- the VPN engines: `openvpn`, `wg-quick` with `wireguard-go`;
- the hook, `Resources/nodens-hook` (POSIX sh), installed to
  `/usr/local/libexec/nodens/hook` (root-owned, mode 755) on every admin action;
- the admin command itself: a fixed shell command built by
  `NodensCore/Root/AdminScript.swift`, run through the standard macOS
  administrator prompt (`do shell script … with administrator privileges`).

There is no privileged helper daemon. Nothing runs as root between actions,
except the engines themselves.

### What Nodens defends against

**A hostile configuration file.** A pasted `.ovpn` or `.conf` file must not
run code as root. Both engines execute hooks from their configuration
(`up`, `plugin`, `PostUp` with bash `eval`), and both tokenize more loosely
than a simple parser. The checks therefore fail closed:

- any control character makes the file unusable (bash trims `\v`, `\f` and
  `\r` from WireGuard keys);
- an OpenVPN option name may contain only letters, digits and dashes (openvpn
  accepts quotes and escapes in every token);
- only key and certificate blocks may be inline in OpenVPN files;
- WireGuard keys must be on an allow-list;
- every directive that runs code, loads code, writes files or changes
  identity is removed (`OpenVPNConfig.removedDirectives`,
  `WireGuardConfig.removedInterfaceKeys`). Nodens' own options come after
  `--config` and override the rest.

**Values passed into root commands.** Profile slugs are `[a-z0-9-]`. DNS
servers must be IP addresses and domains `[a-z0-9.-]`, checked in Swift and
again in the hook. Paths are single-quoted. The hook validates every argument
and environment value it acts on.

**Leftover state.** Every root-side change is recorded and reversible. A
crash or reboot leaves records that the next admin action or **Undo leftover
VPN changes…** reverses. Root copies of configurations, private keys
included, exist only while their tunnel runs.

**Secrets at rest.**
- OpenVPN passwords live in the Keychain.
- Profiles are stored mode 600 in a mode-700 folder.
- The OpenVPN management port listens on 127.0.0.1 only and is protected by
  a random password per tunnel.

### What Nodens does not defend against

- **Malware running as your user.** It can read your profiles, edit them, or
  start a connect that you then approve in the admin prompt. The admin prompt
  shows a fixed description, not the command.
- **The engines themselves.** Bugs in `openvpn` or `wireguard-go` are out of
  scope; keep them updated (`brew upgrade`).
- **A malicious VPN server.** It can push routes and DNS servers. Nodens
  validates pushed DNS values and writes resolver files only for pushed
  domains, but it does not filter pushed routes.

## Verifying a change to root code

Any change to `Resources/nodens-hook` or `AdminScript.swift` must keep
`make check-hook` passing. That target is a syntax check plus dry runs that
print every route and `networksetup` command instead of running it.
