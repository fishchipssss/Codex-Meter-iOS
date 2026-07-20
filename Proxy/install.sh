#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
LOCAL_PORT="${CODEX_METER_PROXY_PORT:-8787}"
TAILSCALE_PORT="${CODEX_METER_TAILSCALE_PORT:-8443}"
CONFIG="${HOME}/.config/codex-meter-proxy/config.json"

for command in python3 codex tailscale; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

codex login status
DNS_NAME="$(tailscale status --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
PUBLIC_URL="https://${DNS_NAME}:${TAILSCALE_PORT}"
CODEX_BINARY="$(command -v codex)"

python3 "$ROOT/codex_meter_proxy.py" --config "$CONFIG" init \
  --public-url "$PUBLIC_URL" --codex-binary "$CODEX_BINARY" --port "$LOCAL_PORT" >/dev/null

if [[ "$(uname -s)" == "Darwin" ]]; then
  PLIST="$HOME/Library/LaunchAgents/com.itsnotmike.codex-meter-proxy.plist"
  mkdir -p "$(dirname "$PLIST")"
  sed -e "s|__PYTHON__|$(command -v python3)|g" \
      -e "s|__SCRIPT__|$ROOT/codex_meter_proxy.py|g" \
      -e "s|__CONFIG__|$CONFIG|g" "$ROOT/support/com.itsnotmike.codex-meter-proxy.plist" > "$PLIST"
  launchctl bootout "gui/$(id -u)/com.itsnotmike.codex-meter-proxy" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
else
  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  sed -e "s|__PYTHON__|$(command -v python3)|g" \
      -e "s|__SCRIPT__|$ROOT/codex_meter_proxy.py|g" \
      -e "s|__CONFIG__|$CONFIG|g" "$ROOT/support/codex-meter-proxy.service" > "$UNIT_DIR/codex-meter-proxy.service"
  systemctl --user daemon-reload
  systemctl --user enable --now codex-meter-proxy.service
fi

tailscale serve --bg --https="$TAILSCALE_PORT" "$LOCAL_PORT"
python3 "$ROOT/codex_meter_proxy.py" --config "$CONFIG" doctor
echo
echo "Paste this setup code into Codex Meter:"
python3 "$ROOT/codex_meter_proxy.py" --config "$CONFIG" pairing-code
