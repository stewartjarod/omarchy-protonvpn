#!/usr/bin/env bash
# Remove the Proton VPN torrent tunnel's system parts:
#   sudo /usr/local/lib/pvpn-torrent/uninstall.sh [--purge]
# --purge also deletes /etc/pvpn-torrent (the WireGuard config and settings).
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 1; }

systemctl disable --now pvpn-torrent.service >/dev/null 2>&1 || true
systemctl stop pvpn-torrent-portfwd.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/pvpn-torrent.service /etc/systemd/system/pvpn-torrent-portfwd.service
systemctl daemon-reload

rm -f /etc/sudoers.d/90-pvpn-torrent
rm -f /usr/local/bin/pvpn-torrent-up /usr/local/bin/pvpn-torrent-down /usr/local/bin/pvpn-torrent-portfwd \
      /usr/local/bin/pvpn-torrent-launch /usr/local/bin/qbittorrent
rm -rf /etc/netns/pvpntor /run/pvpn-torrent

RUN_USER="${SUDO_USER:-}"
if [[ -n "$RUN_USER" ]]; then
  launcher="$(getent passwd "$RUN_USER" | cut -d: -f6)/.local/share/applications/org.qbittorrent.qBittorrent.desktop"
  grep -q '/usr/local/bin/qbittorrent' "$launcher" 2>/dev/null && rm -f "$launcher"
fi

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf /etc/pvpn-torrent
  echo "removed /etc/pvpn-torrent"
fi
rm -rf /usr/local/lib/pvpn-torrent
echo "Proton VPN torrent tunnel removed."
