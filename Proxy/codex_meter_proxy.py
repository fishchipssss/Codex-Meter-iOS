#!/usr/bin/env python3
"""Private, read-minimal Codex usage relay for Codex Meter iOS."""

from __future__ import annotations

import argparse
import datetime as dt
import hmac
import json
import select
import secrets
import socket
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

VERSION = "0.2.1"
PROTOCOL_VERSION = 1
DEFAULT_CONFIG = Path.home() / ".config" / "codex-meter-proxy" / "config.json"


class ProxyFailure(Exception):
    def __init__(self, code: str, message: str, status: int = 503, retryable: bool = True):
        super().__init__(message)
        self.code, self.message, self.status, self.retryable = code, message, status, retryable


def load_config(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ProxyFailure("not_configured", f"Run init first; config not found at {path}.", 500, False) from exc
    required = ("proxy_id", "name", "token", "public_url", "codex_binary", "listen_host", "listen_port")
    if not all(value.get(key) for key in required):
        raise ProxyFailure("invalid_config", "Proxy configuration is incomplete.", 500, False)
    return value


def save_config(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)


class CodexAppServer:
    def __init__(self, binary: str):
        self.binary = binary
        self.process: subprocess.Popen[str] | None = None
        self.lock = threading.RLock()
        self.request_id = 0

    def close(self) -> None:
        with self.lock:
            if self.process and self.process.poll() is None:
                self.process.terminate()
            self.process = None

    def _start(self) -> None:
        self.close()
        try:
            self.process = subprocess.Popen(
                [self.binary, "app-server", "--stdio"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                bufsize=1,
            )
        except OSError as exc:
            raise ProxyFailure("codex_unavailable", "Could not start the Codex CLI.", 503, True) from exc
        result = self._request_unlocked("initialize", {
            "clientInfo": {"name": "codex_meter_proxy", "title": "Codex Meter Proxy", "version": VERSION}
        })
        if not isinstance(result, dict):
            raise ProxyFailure("codex_protocol_error", "Codex initialization returned an invalid response.", 502)
        self._write({"method": "initialized", "params": {}})

    def _write(self, value: dict[str, Any]) -> None:
        if not self.process or not self.process.stdin or self.process.poll() is not None:
            raise BrokenPipeError
        self.process.stdin.write(json.dumps(value, separators=(",", ":")) + "\n")
        self.process.stdin.flush()

    def _request_unlocked(self, method: str, params: Any) -> Any:
        if not self.process or not self.process.stdout:
            raise BrokenPipeError
        self.request_id += 1
        request_id = self.request_id
        self._write({"method": method, "id": request_id, "params": params})
        deadline = time.monotonic() + 20
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                if self.process and self.process.poll() is None:
                    self.process.terminate()
                self.process = None
                raise ProxyFailure("codex_timeout", "The Codex app-server timed out.", 504, True)
            line = self.process.stdout.readline()
            if not line:
                raise BrokenPipeError
            try:
                message = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ProxyFailure("codex_protocol_error", "Codex returned malformed JSON.", 502) from exc
            if message.get("id") != request_id:
                continue
            if "error" in message:
                detail = message.get("error") or {}
                text = str(detail.get("message") or "Codex request failed.")
                if "login" in text.lower() or "auth" in text.lower():
                    raise ProxyFailure("codex_not_authenticated", "Run codex login on the proxy computer.", 503, False)
                raise ProxyFailure("codex_request_failed", text, 502, True)
            return message.get("result")

    def request(self, method: str, params: Any, retry: bool = True) -> Any:
        with self.lock:
            for attempt in range(2 if retry else 1):
                try:
                    if not self.process or self.process.poll() is not None:
                        self._start()
                    return self._request_unlocked(method, params)
                except (BrokenPipeError, OSError):
                    self.process = None
                    if attempt == 0 and retry:
                        continue
                    raise ProxyFailure("codex_unavailable", "The Codex app-server stopped unexpectedly.", 503, True)
        raise ProxyFailure("codex_unavailable", "The Codex app-server is unavailable.")

    def snapshot(self, config: dict[str, Any]) -> dict[str, Any]:
        account_result = self.request("account/read", {"refreshToken": True}) or {}
        account = account_result.get("account") or {}
        if account.get("type") != "chatgpt":
            raise ProxyFailure("codex_not_authenticated", "Sign in to Codex with ChatGPT on the proxy computer.", 503, False)
        rate_result = self.request("account/rateLimits/read", None) or {}
        buckets = rate_result.get("rateLimitsByLimitId") or {}
        rate = buckets.get("codex") or rate_result.get("rateLimits") or {}
        if not rate:
            raise ProxyFailure("no_rate_limits", "Codex returned no account rate limits.", 502, True)
        return {
            "schema_version": PROTOCOL_VERSION,
            "proxy": {"id": config["proxy_id"], "name": config["name"], "relay_version": VERSION},
            "account": {
                "type": "chatgpt",
                "email": account.get("email"),
                "plan_type": account.get("planType") or rate.get("planType"),
            },
            "rate_limit": normalize_rate_limit(rate),
            "reset_credits": normalize_reset_credits(rate_result.get("rateLimitResetCredits")),
            "fetched_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        }

    def consume_reset(self, idempotency_key: str, credit_id: str | None) -> str:
        params: dict[str, Any] = {"idempotencyKey": idempotency_key}
        if credit_id:
            params["creditId"] = credit_id
        result = self.request("account/rateLimitResetCredit/consume", params) or {}
        outcome = result.get("outcome")
        if outcome not in {"reset", "nothingToReset", "noCredit", "alreadyRedeemed"}:
            raise ProxyFailure("codex_protocol_error", "Codex returned an unknown reset outcome.", 502)
        return outcome


def normalize_window(value: Any) -> dict[str, Any] | None:
    if not isinstance(value, dict):
        return None
    return {
        "used_percent": max(0, min(100, int(value.get("usedPercent") or 0))),
        "window_duration_minutes": value.get("windowDurationMins"),
        "resets_at": value.get("resetsAt"),
    }


def normalize_rate_limit(value: dict[str, Any]) -> dict[str, Any]:
    return {
        "limit_id": value.get("limitId"),
        "limit_name": value.get("limitName"),
        "rate_limit_reached_type": value.get("rateLimitReachedType"),
        "primary": normalize_window(value.get("primary")),
        "secondary": normalize_window(value.get("secondary")),
    }


def normalize_reset_credits(value: Any) -> dict[str, Any]:
    value = value if isinstance(value, dict) else {}
    credits = []
    for credit in value.get("credits") or []:
        credits.append({
            "id": credit.get("id") or "",
            "reset_type": credit.get("resetType") or "unknown",
            "status": credit.get("status") or "unknown",
            "granted_at": credit.get("grantedAt"),
            "expires_at": credit.get("expiresAt"),
            "title": credit.get("title"),
            "description": credit.get("description"),
        })
    return {"available_count": max(0, int(value.get("availableCount") or 0)), "credits": credits}


class RelayHandler(BaseHTTPRequestHandler):
    server_version = "CodexMeterProxy/" + VERSION

    @property
    def relay(self) -> "RelayHTTPServer":
        return self.server  # type: ignore[return-value]

    def log_message(self, format: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), format % args))

    def _authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = "Bearer " + self.relay.config["token"]
        return hmac.compare_digest(supplied.encode(), expected.encode())

    def _json(self, status: int, value: dict[str, Any]) -> None:
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _failure(self, failure: ProxyFailure) -> None:
        self._json(failure.status, {"error": {
            "code": failure.code, "message": failure.message, "retryable": failure.retryable
        }})

    def _preflight(self) -> bool:
        if not self._authorized():
            self._failure(ProxyFailure("unauthorized", "The proxy access token is invalid.", 401, False))
            return False
        if self.headers.get("X-Codex-Meter-Protocol") != str(PROTOCOL_VERSION):
            self._failure(ProxyFailure("unsupported_protocol", "Unsupported Codex Meter protocol version.", 400, False))
            return False
        return True

    def do_GET(self) -> None:
        if not self._preflight():
            return
        try:
            if self.path == "/v1/health":
                self._json(200, {
                    "schema_version": PROTOCOL_VERSION,
                    "proxy_id": self.relay.config["proxy_id"],
                    "proxy_name": self.relay.config["name"],
                    "relay_version": VERSION,
                    "codex_ready": True,
                })
            elif self.path == "/v1/snapshot":
                self._json(200, self.relay.codex.snapshot(self.relay.config))
            else:
                self._failure(ProxyFailure("not_found", "Endpoint not found.", 404, False))
        except ProxyFailure as failure:
            self._failure(failure)
        except Exception:
            self._failure(ProxyFailure("internal_error", "The proxy encountered an internal error.", 500, True))

    def do_POST(self) -> None:
        if not self._preflight():
            return
        if self.path != "/v1/reset":
            self._failure(ProxyFailure("not_found", "Endpoint not found.", 404, False))
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > 16_384:
                raise ProxyFailure("invalid_request", "Reset request body is invalid.", 400, False)
            payload = json.loads(self.rfile.read(length))
            key = str(payload.get("idempotency_key") or "")
            uuid.UUID(key)
            credit_id = payload.get("credit_id")
            outcome = self.relay.codex.consume_reset(key, str(credit_id) if credit_id else None)
            self._json(200, {"schema_version": PROTOCOL_VERSION, "outcome": outcome})
        except (ValueError, json.JSONDecodeError, AttributeError):
            self._failure(ProxyFailure("invalid_request", "A UUID idempotency_key is required.", 400, False))
        except ProxyFailure as failure:
            self._failure(failure)


class RelayHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address: tuple[str, int], config: dict[str, Any]):
        super().__init__(address, RelayHandler)
        self.config = config
        self.codex = CodexAppServer(config["codex_binary"])

    def server_close(self) -> None:
        self.codex.close()
        super().server_close()


def pairing_code(config: dict[str, Any]) -> str:
    query = urllib.parse.urlencode({
        "v": PROTOCOL_VERSION,
        "id": config["proxy_id"],
        "name": config["name"],
        "url": config["public_url"].rstrip("/"),
        "token": config["token"],
    })
    return "codexmeter://proxy/add?" + query


def command_init(args: argparse.Namespace) -> None:
    path = Path(args.config).expanduser()
    existing: dict[str, Any] = {}
    if path.exists():
        existing = json.loads(path.read_text(encoding="utf-8"))
    value = {
        "proxy_id": existing.get("proxy_id") or str(uuid.uuid4()),
        "name": args.name or existing.get("name") or socket.gethostname().split(".")[0],
        "token": existing.get("token") or secrets.token_urlsafe(32),
        "public_url": args.public_url.rstrip("/"),
        "codex_binary": args.codex_binary,
        "listen_host": "127.0.0.1",
        "listen_port": args.port,
    }
    save_config(path, value)
    print(pairing_code(value))


def command_doctor(config: dict[str, Any]) -> None:
    codex = CodexAppServer(config["codex_binary"])
    try:
        snapshot = codex.snapshot(config)
        print(json.dumps({
            "ok": True,
            "proxy_id": config["proxy_id"],
            "proxy_name": config["name"],
            "account_type": snapshot["account"]["type"],
            "plan_type": snapshot["account"].get("plan_type"),
            "has_rate_limit": bool(snapshot.get("rate_limit")),
        }, indent=2))
    finally:
        codex.close()


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--config", default=str(DEFAULT_CONFIG))
    sub = value.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    init.add_argument("--name")
    init.add_argument("--public-url", required=True)
    init.add_argument("--codex-binary", default="codex")
    init.add_argument("--port", type=int, default=8787)
    sub.add_parser("serve")
    sub.add_parser("doctor")
    sub.add_parser("pairing-code")
    sub.add_parser("rotate-token")
    return value


def main() -> int:
    args = parser().parse_args()
    try:
        if args.command == "init":
            command_init(args)
            return 0
        path = Path(args.config).expanduser()
        config = load_config(path)
        if args.command == "pairing-code":
            print(pairing_code(config))
        elif args.command == "rotate-token":
            config["token"] = secrets.token_urlsafe(32)
            save_config(path, config)
            print(pairing_code(config))
        elif args.command == "doctor":
            command_doctor(config)
        elif args.command == "serve":
            server = RelayHTTPServer((config["listen_host"], int(config["listen_port"])), config)
            print(f"Codex Meter proxy listening on http://127.0.0.1:{config['listen_port']}", flush=True)
            try:
                server.serve_forever(poll_interval=0.5)
            except KeyboardInterrupt:
                pass
            finally:
                server.server_close()
        return 0
    except ProxyFailure as failure:
        print(f"error: {failure.message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
