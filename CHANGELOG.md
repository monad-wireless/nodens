# Changelog

All notable changes to Nodens are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - not yet released

First public version.

### Added

- Menu-bar app with a two-ring status glyph: Tailscale left, VPN right, with
  off, changing, on and attention states.
- OpenVPN driver: runs `openvpn` as a held root daemon and controls it over a
  password-protected management port on 127.0.0.1. Logins come from the
  Keychain and are sent again after every reconnect.
- WireGuard driver: runs `wg-quick` with `wireguard-go`.
- Tailscale profiles: switch tailnets, bring Tailscale up or down.
- Tailscale coexistence:
  - `/etc/resolver` files for the tailnet's domains;
  - `--accept-dns` handling, restored only on positive evidence;
  - three route strategies that keep Tailscale's traffic routable under a
    full-tunnel VPN.
- Root hook (`nodens-hook`): route fix, IPv6 block on the uplink for full
  tunnels, resolver files for the VPN's domains, persistent records with undo.
  It has a dry-run mode.
- Configuration checks that fail closed, for OpenVPN and WireGuard files.
- Settings window: paste-in profile editor with a live check, Keychain
  passwords, and import from Tunnelblick.

### Known limitations

- The OpenVPN and WireGuard drivers have not completed a live connect yet.
- The best route strategy is not measured yet.
- No binary releases; build from source.

[Unreleased]: https://github.com/monad-wireless/nodens/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/monad-wireless/nodens/releases/tag/v0.1.0
