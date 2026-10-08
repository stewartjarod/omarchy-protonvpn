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
    cities and server names (e.g. `japan`, `zurich`, `nl#38`) within the
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
- Keyboard navigation: `j`/`k`, `enter`, `t`, `c`, `s`, `f`, `b`, `/`, `r`, and `esc`.

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
