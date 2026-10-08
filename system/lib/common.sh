# Shared settings and helpers for the Proton VPN torrent tunnel scripts.
# Sourced by everything in system/bin. Settings live in /etc/pvpn-torrent/
# torrent.conf (written by install.sh); the defaults below apply when a key is
# missing.

NS="pvpntor"                         # network namespace name
WG_IF="pvpntor0"                     # WireGuard interface inside it
WG_CONF="/etc/pvpn-torrent/wg.conf"  # Proton WireGuard config (root, 0600)
TARGET_USER=""                       # desktop user that runs qBittorrent
FALLBACK_DNS="10.2.0.1"              # Proton's in-tunnel resolver
NATPMP_GATEWAY="10.2.0.1"            # Proton's NAT-PMP gateway
QBT_WEBUI_PORT="8080"                # qBittorrent WebUI, bound inside the namespace
RUN_DIR="/run/pvpn-torrent"          # status + forwarded port, world-readable

# shellcheck disable=SC1091
[[ -r /etc/pvpn-torrent/torrent.conf ]] && . /etc/pvpn-torrent/torrent.conf

if [[ -n "$TARGET_USER" ]]; then
  TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || echo "")
fi

# wg_get <file> <section> <key>: first value of key in [section] of a
# wg-quick style config. Case-insensitive section/key, trims whitespace.
wg_get() {
  awk -v want_sec="$(echo "$2" | tr '[:upper:]' '[:lower:]')" -v want_key="$(echo "$3" | tr '[:upper:]' '[:lower:]')" '
    /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[][[:space:]]/, "", sec); next }
    /^[[:space:]]*#/ { next }
    sec == want_sec {
      line = $0
      eq = index(line, "=")
      if (eq == 0) next
      key = tolower(substr(line, 1, eq - 1)); gsub(/[[:space:]]/, "", key)
      if (key != want_key) next
      val = substr(line, eq + 1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      print val; exit
    }' "$1"
}

# Server tag from the config's comments, e.g. "# US-CO#54" -> US-CO#54.
wg_server_tag() {
  grep -oE '^#[[:space:]]*[A-Z]{2}(-[A-Z0-9]+)*#[0-9]+' "$1" 2>/dev/null | head -1 | sed -E 's/^#[[:space:]]*//'
}

ns_exists() {
  [[ -e "/run/netns/$NS" ]]
}
