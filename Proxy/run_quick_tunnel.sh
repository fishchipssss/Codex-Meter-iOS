#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${CODEX_METER_PROXY_CONFIG:-${HOME}/.config/codex-meter-proxy/config.json}"
LOCAL_PORT="${CODEX_METER_PROXY_PORT:-8787}"
updated_url=""

/usr/bin/cloudflared tunnel --no-autoupdate --url "http://127.0.0.1:${LOCAL_PORT}" 2>&1 |
while IFS= read -r line; do
  printf '%s\n' "$line"
  if [[ -z "$updated_url" && "$line" =~ https://[-a-z0-9]+\.trycloudflare\.com ]]; then
    updated_url="${BASH_REMATCH[0]}"
    python3 "$ROOT/codex_meter_proxy.py" --config "$CONFIG" set-public-url \
      --public-url "$updated_url"
    printf 'Codex Meter Quick Tunnel ready at %s\n' "$updated_url"
  fi
done
