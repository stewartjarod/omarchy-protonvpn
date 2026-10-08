# Proton VPN Omarchy bar widget

Status and one-click fastest-server connection for Proton VPN in the menu bar.

![Proton VPN widget preview](preview.png)

## Features

- Bar icon: Adwaita's VPN symbol in the theme color, faded when disconnected,
  full strength when connected, and the "acquiring" variant with pulsing
  dots while a connection is being set up.
- Details panel with:
  - Connected server and location
  - Server load and protocol
  - Session uptime ("Connected for 2h 13m")
  - Live download/upload rates
  - Tunnel IP
  - Collapsible server list with a type filter (click the header or press `s`;
    press `f` or click the "Type" row to cycle): All, Free, Plus, P2P,
    Streaming, Secure Core, Tor. Types your plan can't use are hidden.
  - Search box at the top of the list (`/` to focus): matches countries,
    cities, US states and server names (e.g. `japan`, `zurich`, `texas`,
    `nl#38`) within the
    selected type. `Esc` returns to the list with the query kept, so `j`/`k`,
    `b` and `enter` work on the results.
  - Favorites: star any country, city or server (click the star or press `b`)
    and it shows in a FAVORITES section at the top. Country and city
    favorites remember their type, e.g. P2P in the Netherlands. Saved in the
    widget's entry in `~/.config/omarchy/shell.json`.
  - Click a country to expand its cities, and a city to expand its servers
    (lowest load first). Each level has a "Fastest in ..." row, and picking a
    server connects to that exact one. P2P, Secure Core and Tor also get a
    "Fastest ... server" row at the top
  - Refresh action
- Desktop notifications when the VPN connects, disconnects, or a command fails
  (goes through the shell's notification daemon, so do-not-disturb applies).
- Left click opens the panel. The panel's on/off switch responds to the click
  instantly (optimistically) and reconciles with the real VPN state.
- Right click connects to the fastest eligible Proton server or disconnects.
- Middle click refreshes status.
- Keyboard navigation: `j`/`k`, `enter`, `t`, `c`, `s`, `f`, `b`, `/`, `g` (settings), `m` (map), `r`, and `esc`.

## More features

- **Protection state.** The icon and panel say whether the tunnel is really
  protecting you: *protected* (tunnel up, default route through it, DNS on the
  tunnel, bytes flowing), *not protected* (connected but traffic or DNS
  bypasses it), *no traffic* (nothing received for 3+ minutes), or *blocked*
  (Proton's kill switch is cutting traffic with no tunnel). The panel names the
  reason.
- **Exit IP** of the VPN, fetched through the tunnel interface only (it can
  only succeed through the tunnel), while the panel is open.
- **NETWORK section:** Wi-Fi or interface, local IP, gateway and DNS, plus a
  note when Tailscale is running with the kill switch armed (the kill switch
  blocks tailnet traffic).
- **SETTINGS section** (`g`): kill switch, NetShield, port forwarding, Moderate
  NAT and VPN Accelerator (through `protonvpn config set`), and the protocol
  (WireGuard / OpenVPN UDP / OpenVPN TCP; Proton's CLI has no command for it, so
  this edits `~/.config/Proton/VPN/settings.json` atomically and applies on the
  next connect). Proton's kill switch is `off` or `standard` (block while the
  VPN is active).
- **Always On** (a SETTINGS row, off by default): reconnects after an
  unexpected drop to your last target, waiting 30s between tries and falling
  back to the fastest server after one failed try. A disconnect made from the
  plugin is respected; one made outside it (`protonvpn disconnect` in a
  terminal) can't be told apart from a drop and gets reconnected. Turning it on
  while disconnected connects immediately. After a shell restart it waits for
  your first connect before it acts.
- **MAP** (`m`): an offline world map from bundled Natural Earth outlines and
  the cached server list's coordinates (no tiles, no network). Dots are servers
  for the selected type, favorite countries are highlighted, the connected
  server is ringed, Secure Core shows a dashed entry-to-exit arc, and clicking
  a dot opens that country in the list.

### Polling

The bar mounts one widget per monitor; they elect a leader so there is one
poller, and the other monitor copies its state. Closed, the plugin only samples
cheap state (`nmcli`, `ip`, `resolvectl`, sysfs) every 5 seconds and runs the
Proton CLI when that sample changes, or every 5+ minutes. With the panel open it
asks the CLI every *Status refresh while open* seconds (default 30). This avoids
hammering the CLI, which reads Proton's session through the keyring.

If Proton's keyring entries are ever corrupted by Omarchy's plaintext keyring
(raw newlines in the session key), Proton's loader honours
`PROTON_LOADER_OVERRIDES=keyring=json` in the environment of the `protonvpn`
process. This plugin does not set it (nothing needed it here, and switching the
backend makes the CLI miss an existing session).

## Backend

This plugin uses Proton's official Linux CLI. It does not use `wg-quick`,
static WireGuard files, downloaded server configs, or custom DNS commands.

```bash
protonvpn connect       # fastest eligible server
protonvpn disconnect
protonvpn status
```

The official CLI performs server selection, NetworkManager setup, DNS, and
firewall handling. On a Free plan, Proton selects the fastest available free
server. The GUI and CLI cannot run simultaneously; close `protonvpn-app`
before using the bar toggle with this backend.

## Requirements

- `proton-vpn-cli` installed and signed in
- `wl-copy` for copy actions
- `notify-send` for desktop notifications (disable with the
  `notificationsEnabled` setting if it is not installed)

Install the official Arch package with:

```bash
omarchy pkg add proton-vpn-cli
protonvpn signin
```

## Setup

```bash
ln -s "$(pwd)" ~/.config/omarchy/plugins/tharin.protonvpn
omarchy plugin enable tharin.protonvpn
omarchy bar move tharin.protonvpn --section right
```

The shell hot-reloads changes. Force discovery if needed:

```bash
omarchy-shell shell rescanPlugins
```

## Hotkey

Plain connect (the switch, right click, or enter on the switch) goes back to
the last thing you connected to: a specific server, or "fastest in" the
country/city and type you picked. With no history it uses the fastest server.

To open the panel with the cursor on the on/off switch (enter reconnects or
disconnects, `/` searches), arm the open mode and let the shell open the panel
on the focused monitor. In `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + U", "Proton VPN", "omarchy-shell -q tharin.protonvpn armToggle; omarchy-shell shell toggle tharin.protonvpn")
```

Use `armSearch` instead of `armToggle` to open straight into search.

## Torrent tunnel (optional)

A second Proton WireGuard tunnel just for qBittorrent, independent of the
desktop VPN (based on the design in
[ralphk-86/omarchy-proton](https://github.com/ralphk-86/omarchy-proton)):

- The tunnel lives in its own network namespace (`pvpntor`) whose only way out
  is the tunnel: its own DNS, and a default-deny firewall. If the tunnel is
  down, qBittorrent has no network at all, so it can't leak.
- qBittorrent always starts inside it. A `qbittorrent` wrapper in
  `/usr/local/bin` covers the launcher, magnet links and the terminal, and
  refuses to start when the tunnel is down.
- Toggling or switching the desktop VPN never touches torrents. The tunnel's
  packets bypass the desktop VPN instead of nesting inside it.
- A Proton NAT-PMP port is kept open and set as qBittorrent's listening port
  automatically (through its WebUI, reachable only inside the namespace).
  qBittorrent is also bound to the tunnel interface, so if it is ever started
  outside, it gets no network.
- `pvpn-torrent-check` (the panel's **Check for leaks** row) runs about twenty
  live checks: the namespace holds only the tunnel interface, the default route,
  a recent handshake, the default-deny firewall, the exit address differing from
  your real one, in-tunnel DNS, no `resolve`/`mdns` bypass, IPv6 off, the
  fwmark that keeps the tunnel out of the desktop VPN, the forwarded port
  matching qBittorrent's, every torrent app's real namespace, and the wrapper
  and launchers. Reports are saved to `~/Documents/VPN leak checks/` (newest 20).
  `sudo pvpn-torrent-check --fail-closed` also takes the tunnel down for a few
  seconds to prove nothing gets out.
- Other torrent clients (Transmission, Deluge, rtorrent, ktorrent, aria2c, and
  their system services) running outside the tunnel raise the same error badge
  and notification as qBittorrent. Only qBittorrent is wrapped into the tunnel;
  the others are detected, not moved.
- The torrent tunnel's exit IP is shown in the panel.
- The installer removes the downloaded WireGuard config once the root-only copy
  is installed, since it holds a private key.
- The panel gets a TORRENTS section: tunnel on/off, server, forwarded port,
  last handshake, and whether qBittorrent is inside the tunnel. The bar icon
  warns if qBittorrent is ever found running outside it.

### Install

1. Download a config: account.protonvpn.com → Downloads → WireGuard
   configuration → GNU/Linux, pick a **P2P** server, turn **NAT-PMP (Port
   Forwarding)** on. Each config is its own Proton session; don't reuse it
   elsewhere.
2. Quit qBittorrent.
3. Run:

   ```bash
   sudo ./system/install.sh ~/Downloads/<config>.conf --qbt-config
   ```

   This installs the scripts, `pvpn-torrent.service` (enabled at boot), the
   sudoers rules for starting/stopping the tunnel and launching qBittorrent
   in it (validated with `visudo` first), and a launcher override.
   `--qbt-config` enables qBittorrent's WebUI on 127.0.0.1:8080 with
   localhost auth bypass, so the port can be set (a backup is kept).
4. Start qBittorrent from the launcher or the panel.

To change server, re-run step 3 with another config. To remove:
`sudo /usr/local/lib/pvpn-torrent/uninstall.sh` (`--purge` also deletes
`/etc/pvpn-torrent`).

## Settings

| Key                  | Type    | Default | Meaning                        |
|----------------------|---------|---------|--------------------------------|
| `refreshIntervalSec` | integer | 30      | CLI status poll interval       |
| `notificationsEnabled` | boolean | true  | Desktop notifications on connect/disconnect/failure |

Set it with:

```bash
omarchy bar set tharin.protonvpn refreshIntervalSec 30
```

## Removal

```bash
omarchy plugin disable tharin.protonvpn
rm ~/.config/omarchy/plugins/tharin.protonvpn   # symlink or copied folder
```

To also uninstall the CLI dependency:

```bash
omarchy pkg drop proton-vpn-cli
```
