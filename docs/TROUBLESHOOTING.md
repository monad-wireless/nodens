# Troubleshooting

## Where to look first

| What | Where |
|---|---|
| openvpn and hook output | `/Library/Logs/Nodens/<profile>.log` |
| openvpn start errors (bad options, missing files) | `/Library/Logs/Nodens/<profile>.launch.log` |
| wg-quick and hook output | `/Library/Logs/Nodens/<profile>.log` |
| What the hook changed for a running tunnel | `/usr/local/var/nodens/tunnels/<profile>/` |
| Which resolver files Nodens owns | `/usr/local/var/nodens/resolver/` |
| Tailscale's view | `tailscale status`, `tailscale netcheck`, `tailscale dns status` |
| The resolver order | `scutil --dns` |

`<profile>` is the profile's slug: its name in lowercase, plus a short id,
for example `work-3f2a`. **Settings → Files → Open logs in Finder** opens the
log folder.

## Common situations

**The glyph shows the badge.** Open the menu. The status lines say what
failed. If **Undo leftover VPN changes…** is shown, a tunnel ended without
its down step, for example after a crash or a reboot. Click it to reverse the
recorded routes, the IPv6 setting and the resolver files.

**"The server rejected the username or password."** Open the profile in
Settings, type the password again and save. Nodens does not retry a rejected
login, so the server never locks the account.

**A connect stops with "Tailscale still held the default resolver after 10 s".**
Tailscale did not leave the default DNS slot. Run `scutil --dns`. If
100.100.100.100 is still resolver #1, quit and reopen the Tailscale app, then
connect again.

**Tailnet names do not resolve while the VPN is up.** Check that the
"Keep tailnet names working" switch is on, and that `/etc/resolver` holds a
file for the tailnet's domain. Split-DNS domains need their resolver to be
reachable through the tailnet.

**Tailscale shows offline while a full-tunnel VPN is up.** The route fix did
not work on this Mac. Pick another strategy in Settings, reconnect, and see
[TAILSCALE.md](TAILSCALE.md#testing-a-strategy-by-hand).

**Tailscale DNS stays off after quitting Nodens.** Nodens restores it when the
last tunnel goes down. If you quit Nodens while a VPN was up, start it again
and it restores once no tunnel runs, or run `tailscale set --accept-dns=true`.

## Uninstalling

1. Disconnect every profile.
2. In **Settings → DNS**, click **Remove tailnet DNS files…**.
3. Quit Nodens and delete it from `~/Applications`.
4. Remove the root files and the user data:

   ```sh
   sudo rm -rf /usr/local/libexec/nodens /usr/local/etc/nodens /usr/local/var/nodens /Library/Logs/Nodens
   rm -rf ~/Library/Application\ Support/Nodens
   defaults delete io.github.monad-wireless.nodens
   ```

5. In Keychain Access, delete the items named "Nodens: <profile>".
