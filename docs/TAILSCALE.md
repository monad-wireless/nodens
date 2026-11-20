# Tailscale and a full-tunnel VPN on macOS

This page explains why Tailscale stops working when a full-tunnel VPN
connects on macOS, and what Nodens does about it.

## Two separate problems

### 1. DNS

With "Use Tailscale DNS" on, Tailscale's resolver 100.100.100.100 becomes the
default resolver of the Mac. `scutil --dns` lists it first, ahead of Wi-Fi.
A VPN client such as Tunnelblick writes the VPN's DNS servers onto the Wi-Fi
service, behind Tailscale's resolver. Both programs then believe they own DNS.

Tailscale forwards every name outside the tailnet to its upstream resolvers.
It sends those queries from the physical interface, so under a full tunnel
they fail (see problem 2). The result: no name resolves at all, and the Mac
looks offline.

**What Nodens does.** While a VPN is connected:

1. It writes `/etc/resolver/<domain>` files for the tailnet's own domains:
   - the MagicDNS suffix goes to 100.100.100.100;
   - the parent domain of each extra DNS record (for example Headscale's
     `extra_records`) under a private top-level label (`.internal`, `.lan`,
     `.home`, `.corp`, `.intranet`, `.private`, `.test`, `.tailnet`) goes to
     100.100.100.100;
   - each split-DNS route goes to its own resolver.
2. It runs `tailscale set --accept-dns=false`, so Tailscale leaves the default
   slot.
3. When the last tunnel goes down, it runs `--accept-dns=true` again.

Measured on Tailscale 1.102.2 with `--accept-dns=false`:

| Check | Result |
|---|---|
| Default resolver | the router, within 2 s |
| 100.100.100.100, MagicDNS name | answers |
| 100.100.100.100, extra DNS record | answers |
| 100.100.100.100, split-DNS domain | SERVFAIL, so Nodens points those domains at their own resolver |

### 2. Routes

Tailscale binds its own encrypted traffic (to the control server, to relays
and to peers) to the physical interface, for example `en0`. Its log shows this
as `Rebind; defIf="en0"`.

A full-tunnel VPN (OpenVPN `redirect-gateway def1`, or WireGuard
`AllowedIPs = 0.0.0.0/0`) adds `0/1` and `128/1` routes through the tunnel.
The default route via Wi-Fi stays.

Measured with an OpenVPN server that pushes `redirect-gateway def1`:

- A socket bound to Wi-Fi (`ping -b en0`) got `No route to host` for every
  Internet address, but still reached the router.
- Tailscale's log showed every dial failing with
  `connect: network is unreachable`.
- `tailscale netcheck` reported `UDP: false` and no reachable relay.
- The relay server itself was reachable through the VPN tunnel.

So Tailscale lost its control server and its relays, and the tailnet carried
nothing. The exact kernel rule behind "no route" for an interface-bound socket
is not documented. It is a reasonable inference that the more specific `0/1`
and `128/1` routes on the tunnel win over the default route, which a socket
bound to Wi-Fi may use.

**What Nodens does.** While a full tunnel is up, the hook adds routes for
Tailscale's traffic via the uplink gateway. Three strategies are available
under **Settings → Tailscale under a full-tunnel VPN**:

| Strategy | Routes added |
|---|---|
| Host routes (default) | a `/32` route via the uplink gateway to each control and relay server of the current tailnet |
| Scoped default | `route add -ifscope <uplink> default <gateway>` |
| Scoped halves | `route add -ifscope <uplink> -net 0.0.0.0/1` and `128.0.0.0/1` |

Host routes are the narrowest. They cover the control server and the relays,
so direct peer-to-peer paths fall back to relays. That is slower but works.
Nodens resolves the addresses from `tailscale debug prefs` (`ControlURL`) and
`tailscale debug derp-map` before the VPN comes up.

Which strategy works can differ between macOS versions. Please report your
result in an issue.

## Testing a strategy by hand

Test a route on its own before you trust it. Connect your VPN with any client,
stay on your tailnet, then run these one at a time. Replace `<relay-ip>` with
an address from `tailscale debug derp-map` and `<gateway>` with your router
from `netstat -rn -f inet | grep default`:

```sh
sudo route -n add -host <relay-ip> <gateway>
ping -b en0 -c 3 <relay-ip>          # a Wi-Fi-bound socket: replies expected
tailscale ping -c 3 <peer-ip>        # a pong expected
sudo route -n delete -host <relay-ip>
```

If the bound ping gets no reply, try a scoped default instead:
`sudo route -n add -ifscope en0 default <gateway>`, and remove it with
`sudo route -n delete -ifscope en0 default`.

## IPv6

Most full-tunnel VPN profiles carry only IPv4. Without care, IPv6 traffic
would leave outside the tunnel, and a website would see the home address
instead of the VPN's. For a full IPv4 tunnel without `::/1` through the
tunnel, the hook turns IPv6 off on the uplink service only (for example
Wi-Fi), never on other services, and turns it back on at disconnect.
