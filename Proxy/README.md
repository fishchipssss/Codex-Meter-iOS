# Codex Meter CLI proxy

This helper exposes the active Codex CLI account's usage to Codex Meter over private Tailscale HTTPS. It never sends `auth.json` or OAuth tokens to the phone. The HTTP relay listens only on `127.0.0.1`; Tailscale Serve is the only remote entry point.

## Install

Requirements:

- macOS or Linux
- Python 3.10+
- a current Codex CLI signed in with ChatGPT (`codex login status`)
- Tailscale connected on the computer and iPhone

From the repository:

```bash
./Proxy/install.sh
```

The installer creates a user service, exposes local port `8787` through Tailscale Serve HTTPS port `8443`, verifies Codex, and prints a `codexmeter://proxy/add?...` setup code. In the app choose **Add account → Codex CLI proxy**, paste the code, then select **Test and add proxy**.

Override ports when needed:

```bash
CODEX_METER_PROXY_PORT=8788 CODEX_METER_TAILSCALE_PORT=9443 ./Proxy/install.sh
```

## Operations

```bash
python3 Proxy/codex_meter_proxy.py doctor
python3 Proxy/codex_meter_proxy.py pairing-code
python3 Proxy/codex_meter_proxy.py rotate-token
./Proxy/uninstall.sh
```

The default config is `~/.config/codex-meter-proxy/config.json` with mode `0600`. Rotating the token prints a replacement setup code; add that code in the app to update the saved connection.

The uninstall script removes the user service and Tailscale Serve port. It intentionally leaves the config file so it cannot accidentally destroy the proxy identity; delete the directory manually if desired.

## Troubleshooting

- Run `codex login status`, then `codex login` if the CLI is signed out.
- Run `python3 Proxy/codex_meter_proxy.py doctor` as the same user that installed the service.
- Run `tailscale serve status` and confirm HTTPS port `8443` points to `http://127.0.0.1:8787`.
- On iPhone, keep Tailscale connected. VPN On Demand for `*.ts.net` improves background refresh reliability.
- The proxy is tailnet-only. Do not replace `tailscale serve` with `tailscale funnel`.
