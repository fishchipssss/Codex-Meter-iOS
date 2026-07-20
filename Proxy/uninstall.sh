#!/usr/bin/env bash
set -euo pipefail
TAILSCALE_PORT="${CODEX_METER_TAILSCALE_PORT:-8443}"
if [[ "$(uname -s)" == "Darwin" ]]; then
  launchctl bootout "gui/$(id -u)/com.itsnotmike.codex-meter-proxy" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/com.itsnotmike.codex-meter-proxy.plist"
else
  systemctl --user disable --now codex-meter-proxy.service 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/codex-meter-proxy.service"
  systemctl --user daemon-reload
fi
tailscale serve --https="$TAILSCALE_PORT" off 2>/dev/null || true
echo "Service removed. Credentials remain in ~/.config/codex-meter-proxy until you delete them."
