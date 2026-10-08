#!/usr/bin/env bash
# ============================================================================
#  Proton VPN torrent tunnel - system install.
#
#    sudo ./system/install.sh [path/to/proton-wireguard.conf] [--qbt-config]
#
#  Installs the namespace scripts, systemd units, sudoers rules and the
#  `qbittorrent` wrapper. With a config path, installs that Proton WireGuard
#  config as the torrent server and starts the tunnel. Re-run with a new
#  config to change server.
#
#  --qbt-config  enable qBittorrent's WebUI on 127.0.0.1:8080 with localhost
#                auth bypass (inside the namespace only) so the forwarded port
#                can be set automatically. qBittorrent must be closed; a backup
#                of qBittorrent.conf is kept.
#
#  Get a config: account.protonvpn.com -> Downloads -> WireGuard configuration
#  -> GNU/Linux, a P2P server, "NAT-PMP (Port Forwarding)" ON.
# ============================================================================
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run with sudo: sudo $0 $*"
RUN_USER="${SUDO_USER:-}"
[[ -n "$RUN_USER" && "$RUN_USER" != "root" ]] || die "run via sudo from your desktop user, not as root directly"
RUN_HOME="$(getent passwd "$RUN_USER" | cut -d: -f6)"

CONF_IN=""
QBT_CONFIG=0
for arg in "$@"; do
  case "$arg" in
    --qbt-config) QBT_CONFIG=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) CONF_IN="$arg" ;;
  esac
done

for dep in wg nft natpmpc curl ip runuser visudo; do
  command -v "$dep" >/dev/null || die "missing dependency: $dep (omarchy pkg add wireguard-tools nftables libnatpmp curl)"
done
[[ -x /usr/bin/qbittorrent ]] || warn "qbittorrent is not installed (omarchy pkg add qbittorrent)"

. "$SRC/lib/common.sh"   # defaults (NS, WG_IF, ...) for this script

# --- validate the config before touching anything ----------------------------
if [[ -n "$CONF_IN" ]]; then
  [[ -r "$CONF_IN" ]] || die "cannot read $CONF_IN"
  for want in "interface PrivateKey" "interface Address" "peer PublicKey" "peer Endpoint"; do
    # shellcheck disable=SC2086
    [[ -n "$(wg_get "$CONF_IN" $want)" ]] || die "$CONF_IN has no $want - is it a WireGuard config?"
  done
  if grep -qiE '^#[[:space:]]*NAT-PMP.*=[[:space:]]*off' "$CONF_IN"; then
    warn "this config was made with NAT-PMP (Port Forwarding) OFF; port forwarding will fail."
    warn "Download a new one with it ON for best torrent speeds."
  fi
fi

# --- files -------------------------------------------------------------------
say "Installing scripts"
install -d -m 755 /usr/local/lib/pvpn-torrent
install -m 644 "$SRC/lib/common.sh" /usr/local/lib/pvpn-torrent/common.sh
install -m 755 "$SRC/uninstall.sh" /usr/local/lib/pvpn-torrent/uninstall.sh
for f in pvpn-torrent-up pvpn-torrent-down pvpn-torrent-portfwd pvpn-torrent-launch qbittorrent; do
  install -m 755 "$SRC/bin/$f" "/usr/local/bin/$f"
done

say "Writing /etc/pvpn-torrent/torrent.conf"
install -d -m 755 /etc/pvpn-torrent
if [[ -f /etc/pvpn-torrent/torrent.conf ]]; then
  sed -i "s/^TARGET_USER=.*/TARGET_USER=\"$RUN_USER\"/" /etc/pvpn-torrent/torrent.conf
  echo "    kept existing settings"
else
  cat > /etc/pvpn-torrent/torrent.conf <<CONF
# Proton VPN torrent tunnel settings (see /usr/local/lib/pvpn-torrent/common.sh)
TARGET_USER="$RUN_USER"
NS="pvpntor"
WG_IF="pvpntor0"
QBT_WEBUI_PORT="8080"
CONF
  chmod 644 /etc/pvpn-torrent/torrent.conf
fi

if [[ -n "$CONF_IN" ]]; then
  say "Installing $(basename "$CONF_IN") as the torrent server ($(wg_server_tag "$CONF_IN"))"
  install -m 600 -o root -g root "$CONF_IN" /etc/pvpn-torrent/wg.conf
fi

# --- sudoers (validated before install: a broken file locks sudo) ------------
say "Installing sudoers rules"
tmp=$(mktemp)
sed "s/@USER@/$RUN_USER/g" "$SRC/sudoers.d/90-pvpn-torrent" > "$tmp"
visudo -c -f "$tmp" >/dev/null || { rm -f "$tmp"; die "generated sudoers file is invalid - aborting"; }
install -m 440 -o root -g root "$tmp" /etc/sudoers.d/90-pvpn-torrent
rm -f "$tmp"

# --- systemd -----------------------------------------------------------------
say "Installing systemd units"
install -m 644 "$SRC/systemd/pvpn-torrent.service" /etc/systemd/system/pvpn-torrent.service
install -m 644 "$SRC/systemd/pvpn-torrent-portfwd.service" /etc/systemd/system/pvpn-torrent-portfwd.service
systemctl daemon-reload
systemctl enable pvpn-torrent.service >/dev/null 2>&1

# --- desktop launcher: go through the wrapper (magnet links too) -------------
say "Pointing the qBittorrent launcher at the tunnel wrapper"
APPS="$RUN_HOME/.local/share/applications"
runuser -u "$RUN_USER" -- install -d -m 755 "$APPS"
if [[ -f /usr/share/applications/org.qbittorrent.qBittorrent.desktop ]]; then
  sed -E 's#^Exec=qbittorrent#Exec=/usr/local/bin/qbittorrent#' /usr/share/applications/org.qbittorrent.qBittorrent.desktop \
    | runuser -u "$RUN_USER" -- tee "$APPS/org.qbittorrent.qBittorrent.desktop" >/dev/null
fi

# --- qBittorrent WebUI (optional) --------------------------------------------
if (( QBT_CONFIG )); then
  QCONF="$RUN_HOME/.config/qBittorrent/qBittorrent.conf"
  if pgrep -u "$RUN_USER" -x qbittorrent >/dev/null; then
    warn "qBittorrent is running; it rewrites its config on exit. Close it and re-run with --qbt-config."
  elif [[ ! -f "$QCONF" ]]; then
    warn "$QCONF not found; start qBittorrent once, close it, and re-run with --qbt-config."
  else
    say "Enabling qBittorrent WebUI on 127.0.0.1:$QBT_WEBUI_PORT (localhost auth bypass)"
    runuser -u "$RUN_USER" -- cp -p "$QCONF" "$QCONF.bak.$(date +%s)"
    runuser -u "$RUN_USER" -- python3 -I - "$QCONF" "$QBT_WEBUI_PORT" <<'PY'
import sys
path, port = sys.argv[1], sys.argv[2]
want = {"WebUI\\Enabled": "true", "WebUI\\Address": "127.0.0.1", "WebUI\\Port": port,
        "WebUI\\LocalHostAuth": "false", "WebUI\\UseUPnP": "false"}
lines = open(path).read().splitlines()
out, in_prefs, seen_prefs, done = [], False, False, set()
def flush():
    for k, v in want.items():
        if k not in done:
            out.append(f"{k}={v}")
            done.add(k)
for line in lines:
    if line.startswith("["):
        if in_prefs:
            flush()
        in_prefs = line.strip() == "[Preferences]"
        seen_prefs = seen_prefs or in_prefs
    elif in_prefs and "=" in line and line.split("=", 1)[0] in want:
        k = line.split("=", 1)[0]
        line = f"{k}={want[k]}"
        done.add(k)
    out.append(line)
if in_prefs:
    flush()
if not seen_prefs:
    out += ["", "[Preferences]"]
    flush()
open(path, "w").write("\n".join(out) + "\n")
PY
  fi
fi

# --- start -------------------------------------------------------------------
if [[ -r /etc/pvpn-torrent/wg.conf ]]; then
  say "Starting the torrent tunnel"
  systemctl restart pvpn-torrent.service || die "pvpn-torrent.service failed: journalctl -u pvpn-torrent.service"
  sleep 2
  ip -n "$NS" -brief addr show "$WG_IF" || true
  say "Done. qBittorrent now only starts inside the tunnel (launcher, magnet links, \`qbittorrent\`)."
  pgrep -u "$RUN_USER" -x qbittorrent >/dev/null && warn "qBittorrent is running OUTSIDE the tunnel right now - quit it and start it again."
else
  say "Installed. Add a Proton WireGuard config to start the tunnel:"
  echo "    sudo $0 /path/to/proton-wireguard.conf"
fi
