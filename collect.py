#!/usr/bin/env python3
"""Collect subscription usage into a local JSON cache."""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

HOME = Path.home()
CACHE_DIR = HOME / ".cache" / "usage-rail"
CACHE_PATH = CACHE_DIR / "usage.json"
CODEX_AUTH = HOME / ".codex" / "auth.json"
GROK_AUTH = HOME / ".grok" / "auth.json"
KIMI_AUTH = HOME / ".kimi" / "credentials" / "kimi-code.json"
CLAUDE_AUTH = HOME / ".claude" / ".credentials.json"
CLAUDE_KEYCHAIN = "Claude Code-credentials"

CODEX_USAGE_URL = "https://chatgpt.com/backend-api/wham/usage"
GROK_BILLING_URL = "https://cli-chat-proxy.grok.com/v1/billing?format=credits"
KIMI_USAGES_URL = "https://api.kimi.com/coding/v1/usages"
KIMI_TOKEN_URL = "https://auth.kimi.com/api/oauth/token"
KIMI_CLIENT_ID = "17e5f671-d194-4dfb-9706-5516cb48c098"
CLAUDE_USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
DEEPSEEK_BALANCE_URL = "https://api.deepseek.com/user/balance"


def _now() -> float:
    return time.time()


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _http_json(
    url: str,
    headers: dict[str, str],
    timeout: int = 20,
    data: bytes | None = None,
    method: str | None = None,
) -> tuple[int | None, Any]:
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            if not raw:
                return resp.status, {}
            try:
                return resp.status, json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                return resp.status, {"error": "non_json"}
    except urllib.error.HTTPError as e:
        body = e.read()[:500].decode("utf-8", "replace")
        try:
            parsed = json.loads(body)
        except Exception:
            parsed = {"error": body[:200]}
        return e.code, parsed
    except Exception as e:
        return None, {"error": f"{type(e).__name__}"}


def _parse_reset(value: Any) -> int | None:
    if value is None or value == "":
        return None
    if isinstance(value, (int, float)):
        n = int(value)
        if n > 10**12:
            n //= 1000
        return n if n > 0 else None
    if isinstance(value, str):
        text = value.strip()
        if text.isdigit():
            return _parse_reset(int(text))
        try:
            if text.endswith("Z"):
                text = text[:-1] + "+00:00"
            dt = datetime.fromisoformat(text)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return int(dt.timestamp())
        except Exception:
            return None
    return None


def _window(used: float | None, reset_at: int | None, label: str) -> dict[str, Any]:
    used_percent = None if used is None else round(float(used), 1)
    reset_after = None
    if reset_at:
        reset_after = max(0, int(reset_at - _now()))
    return {
        "label": label,
        "used_percent": used_percent,
        "reset_at": reset_at,
        "reset_after_seconds": reset_after,
    }


def _jwt_exp(token: str) -> int | None:
    try:
        parts = token.split(".")
        if len(parts) < 2:
            return None
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload.encode("ascii")))
        exp = data.get("exp")
        return int(exp) if exp else None
    except Exception:
        return None


def _fail(kind: str, error: str) -> dict[str, Any]:
    return {"ok": False, "error": error, "kind": kind}


# --- Codex / GPT ----------------------------------------------------------

def _codex_headers(auth: dict[str, Any]) -> dict[str, str]:
    tokens = auth.get("tokens") or {}
    headers = {
        "Authorization": f"Bearer {tokens.get('access_token') or ''}",
        "OpenAI-Beta": "codex_cli",
        "User-Agent": "usage-rail/1",
    }
    account_id = tokens.get("account_id")
    if account_id:
        headers["ChatGPT-Account-ID"] = str(account_id)
    return headers


def fetch_codex() -> dict[str, Any]:
    if not CODEX_AUTH.exists():
        return _fail("gpt", "codex_auth_missing")
    try:
        auth = json.loads(CODEX_AUTH.read_text(encoding="utf-8"))
    except Exception:
        return _fail("gpt", "codex_auth_parse")

    status, data = _http_json(CODEX_USAGE_URL, _codex_headers(auth))
    if status != 200 or not isinstance(data, dict) or "rate_limit" not in data:
        return _fail("gpt", f"codex_http_{status}")

    rate = data.get("rate_limit") or {}
    primary = rate.get("primary_window") or {}
    secondary = rate.get("secondary_window") or {}

    session = _window(
        primary.get("used_percent"),
        _parse_reset(primary.get("reset_at")),
        "5h",
    )
    weekly = _window(
        secondary.get("used_percent"),
        _parse_reset(secondary.get("reset_at")),
        "weekly",
    )
    return {
        "ok": True,
        "kind": "gpt",
        "plan": data.get("plan_type") or "",
        "allowed": bool(rate.get("allowed", True)),
        "limit_reached": bool(rate.get("limit_reached", False)),
        "session": session,
        "weekly": weekly,
    }


# --- Grok -----------------------------------------------------------------

def _grok_auth_paths() -> list[Path]:
    found: list[Path] = []
    seen: set[Path] = set()
    candidates = [GROK_AUTH]
    for path in candidates:
        try:
            if not path.is_file():
                continue
            key = path.resolve()
        except OSError:
            continue
        if key in seen:
            continue
        seen.add(key)
        found.append(path)
    return found


def _load_grok_file(path: Path) -> tuple[str, dict[str, Any]] | None:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None
    if not isinstance(raw, dict):
        return None
    for name, value in raw.items():
        if isinstance(value, dict) and value.get("key"):
            return str(name), value
    return None


def _grok_token_endpoint(issuer: str) -> str:
    issuer = (issuer or "https://auth.x.ai").rstrip("/")
    if issuer.endswith("/oauth2"):
        return f"{issuer}/token"
    return f"{issuer}/oauth2/token"


def _save_grok_entry(path: Path, key_name: str, entry: dict[str, Any]) -> None:
    target = path.resolve() if path.is_symlink() else path
    try:
        raw = json.loads(target.read_text(encoding="utf-8"))
    except Exception:
        raw = {}
    if not isinstance(raw, dict):
        raw = {}
    raw[key_name] = entry
    tmp = target.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(raw, indent=2) + "\n", encoding="utf-8")
    tmp.chmod(0o600)
    tmp.replace(target)


def _grok_refresh(entry: dict[str, Any]) -> dict[str, Any] | None:
    refresh = entry.get("refresh_token")
    client_id = entry.get("oidc_client_id")
    issuer = (entry.get("oidc_issuer") or "https://auth.x.ai").rstrip("/")
    if not refresh or not client_id:
        return None
    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": client_id,
        }
    ).encode("utf-8")
    status, data = _http_json(
        _grok_token_endpoint(issuer),
        {
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": "usage-rail/1",
        },
        data=body,
        method="POST",
    )
    if status != 200 or not isinstance(data, dict):
        return None
    token = data.get("access_token")
    if not token:
        return None
    entry = dict(entry)
    entry["key"] = token
    if data.get("refresh_token"):
        entry["refresh_token"] = data["refresh_token"]
    expires_in = data.get("expires_in")
    if expires_in:
        entry["expires_at"] = datetime.fromtimestamp(
            _now() + int(expires_in), tz=timezone.utc
        ).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    return entry


def _grok_session() -> tuple[str, bool]:
    loaded: list[tuple[Path, str, dict[str, Any], int]] = []
    for path in _grok_auth_paths():
        item = _load_grok_file(path)
        if not item:
            continue
        key_name, entry = item
        exp = _jwt_exp(entry.get("key") or "") or 0
        loaded.append((path, key_name, entry, exp))
    if not loaded:
        return "", False

    now = _now()
    loaded.sort(key=lambda item: item[3], reverse=True)
    for path, key_name, entry, exp in loaded:
        if exp >= now + 90:
            return str(entry.get("key") or ""), False

    for path, key_name, entry, _exp in loaded:
        refreshed = _grok_refresh(entry)
        if not refreshed:
            continue
        try:
            _save_grok_entry(path, key_name, refreshed)
        except OSError:
            pass
        return str(refreshed.get("key") or ""), True
    return "", False


def _grok_headers(token: str) -> dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "X-XAI-Token-Auth": "xai-grok-cli",
        "Accept": "application/json",
        "User-Agent": "usage-rail/1",
    }


def fetch_grok() -> dict[str, Any]:
    token, _refreshed = _grok_session()
    if not token:
        return _fail("grok", "grok_auth_missing")

    status, data = _http_json(GROK_BILLING_URL, _grok_headers(token))
    if status != 200 or not isinstance(data, dict):
        return _fail("grok", f"grok_http_{status}")

    config = data.get("config") or data
    percent = config.get("creditUsagePercent")
    if percent is None:
        return _fail("grok", "grok_percent_omitted")
    if isinstance(percent, (int, float)) and 0 <= percent <= 1.5:
        percent = percent * 100.0

    period = config.get("currentPeriod") or {}
    reset_at = _parse_reset(period.get("end") or config.get("billingPeriodEnd"))
    products = []
    for item in config.get("productUsage") or []:
        if isinstance(item, dict) and item.get("usagePercent") is not None:
            products.append(
                {
                    "product": item.get("product"),
                    "used_percent": round(float(item["usagePercent"]), 1),
                }
            )
    ptype = str(period.get("type") or "")
    label = "weekly" if "WEEKLY" in ptype.upper() else "period"
    window = _window(float(percent), reset_at, label)
    return {
        "ok": True,
        "kind": "grok",
        "period": label,
        "weekly": window,
        "products": products,
    }


# --- Kimi -----------------------------------------------------------------

def _unix_deadline(value: Any) -> float:
    try:
        n = float(value)
    except (TypeError, ValueError):
        return 0
    if n > 10**12:
        return n / 1000.0
    return n


def _write_json(path: Path, raw: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(raw, indent=2) + "\n", encoding="utf-8")
    tmp.chmod(0o600)
    tmp.replace(path)


def _kimi_session() -> str:
    if not KIMI_AUTH.is_file():
        return ""
    try:
        raw = json.loads(KIMI_AUTH.read_text(encoding="utf-8"))
    except Exception:
        return ""
    if not isinstance(raw, dict):
        return ""
    access = str(raw.get("access_token") or "")
    if _unix_deadline(raw.get("expires_at")) >= _now() + 90 and access:
        return access
    refresh = raw.get("refresh_token")
    if not refresh:
        return access
    body = urllib.parse.urlencode(
        {
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": KIMI_CLIENT_ID,
        }
    ).encode("utf-8")
    status, data = _http_json(
        KIMI_TOKEN_URL,
        {
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": "usage-rail/1",
        },
        data=body,
        method="POST",
    )
    if status != 200 or not isinstance(data, dict) or not data.get("access_token"):
        return access
    raw["access_token"] = data["access_token"]
    if data.get("refresh_token"):
        raw["refresh_token"] = data["refresh_token"]
    if data.get("expires_in"):
        raw["expires_at"] = _now() + int(data["expires_in"])
        raw["expires_in"] = data["expires_in"]
    if data.get("scope"):
        raw["scope"] = data["scope"]
    if data.get("token_type"):
        raw["token_type"] = data["token_type"]
    try:
        _write_json(KIMI_AUTH, raw)
    except OSError:
        pass
    return str(raw.get("access_token") or "")


def _ratio_percent(node: Any) -> float | None:
    if not isinstance(node, dict):
        return None
    if node.get("used_ratio") is not None:
        try:
            return float(node["used_ratio"]) * 100.0
        except Exception:
            return None
    try:
        limit = float(node.get("limit"))
        if limit <= 0:
            return None
        if node.get("used") is not None:
            return float(node["used"]) / limit * 100.0
        if node.get("remaining") is not None:
            return (1.0 - float(node["remaining"]) / limit) * 100.0
    except Exception:
        return None
    return None


def fetch_kimi() -> dict[str, Any]:
    key = _kimi_session()
    if not key:
        return _fail("kimi", "kimi_auth_missing")
    status, data = _http_json(
        KIMI_USAGES_URL,
        {
            "Authorization": f"Bearer {key}",
            "Accept": "application/json",
            "User-Agent": "usage-rail/1",
        },
    )
    if status != 200 or not isinstance(data, dict):
        return _fail("kimi", f"kimi_http_{status}")

    usages = data.get("usages") or {}
    month = usages.get("limit_month_total") or {}
    month_code = usages.get("limit_month_code") or {}
    five = usages.get("limit_5h") or {}

    month_pct = _ratio_percent(month)
    if month_pct is None:
        total = data.get("usage") or data.get("totalQuota") or {}
        month_pct = _ratio_percent(total)
        month_reset = _parse_reset(total.get("resetTime") or total.get("reset_time"))
    else:
        month_reset = _parse_reset(month.get("reset_time"))

    five_pct = _ratio_percent(five)
    five_reset = _parse_reset(five.get("reset_time"))
    if five_pct is None:
        for item in data.get("limits") or []:
            window = (item or {}).get("window") or {}
            duration = window.get("duration")
            unit = str(window.get("timeUnit") or "")
            minutes = None
            if duration is not None:
                if "MINUTE" in unit:
                    minutes = int(duration)
                elif "HOUR" in unit:
                    minutes = int(duration) * 60
            if minutes == 300:
                detail = item.get("detail") or {}
                remaining = detail.get("remaining")
                limit = detail.get("limit")
                try:
                    if remaining is not None and limit is not None:
                        five_pct = (1.0 - float(remaining) / float(limit)) * 100.0
                    five_reset = _parse_reset(detail.get("resetTime"))
                except Exception:
                    pass

    membership = ((data.get("user") or {}).get("membership") or {}).get("level")
    return {
        "ok": True,
        "kind": "kimi",
        "plan": membership or "",
        "monthly": _window(month_pct, month_reset, "monthly"),
        "month_code": _window(_ratio_percent(month_code), _parse_reset((month_code or {}).get("reset_time")), "month_code"),
        "session": _window(five_pct, five_reset, "5h"),
    }


# --- Claude ---------------------------------------------------------------

def _claude_usable(raw: dict[str, Any]) -> bool:
    oauth = raw.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return False
    return bool(oauth.get("accessToken") or oauth.get("refreshToken"))


def _claude_services() -> list[str]:
    names: list[str] = []
    dump = subprocess.run(["security", "dump-keychain"], capture_output=True, text=True)
    for match in re.finditer(
        r'"svce"<blob>="(Claude Code-credentials(?:-[0-9a-fA-F]+)?)"',
        dump.stdout,
    ):
        name = match.group(1)
        if name not in names:
            names.append(name)
    if CLAUDE_KEYCHAIN not in names:
        names.insert(0, CLAUDE_KEYCHAIN)
    return names


def _read_keychain(service: str) -> tuple[tuple[str, str, str], dict[str, Any]] | None:
    meta = subprocess.run(
        ["security", "find-generic-password", "-s", service],
        capture_output=True,
        text=True,
    )
    account = ""
    match = re.search(r'"acct"<blob>="((?:\\.|[^"])*)"', meta.stdout)
    if match:
        account = match.group(1)
    proc = subprocess.run(
        ["security", "find-generic-password", "-s", service, "-w"],
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        raw = json.loads(proc.stdout)
    except Exception:
        return None
    if not isinstance(raw, dict) or not _claude_usable(raw):
        return None
    return ("keychain", account, service), raw


def _claude_candidates() -> list[tuple[Any, dict[str, Any]]]:
    found: list[tuple[Any, dict[str, Any]]] = []
    if CLAUDE_AUTH.is_file():
        try:
            raw = json.loads(CLAUDE_AUTH.read_text(encoding="utf-8"))
        except Exception:
            raw = None
        if isinstance(raw, dict) and _claude_usable(raw):
            found.append(("file", raw))
    for service in _claude_services():
        loaded = _read_keychain(service)
        if loaded:
            found.append(loaded)
    found.sort(
        key=lambda item: _unix_deadline((item[1].get("claudeAiOauth") or {}).get("expiresAt")),
        reverse=True,
    )
    return found


def _claude_save(where: Any, raw: dict[str, Any]) -> None:
    if where == "file":
        _write_json(CLAUDE_AUTH, raw)
        return
    _kind, account, service = where
    subprocess.run(
        [
            "security",
            "add-generic-password",
            "-U",
            "-s",
            service,
            "-a",
            account,
            "-w",
            json.dumps(raw, separators=(",", ":")),
            "-T",
            "/usr/bin/security",
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def _claude_token() -> str:
    fallback = ""
    for where, raw in _claude_candidates():
        oauth = raw.get("claudeAiOauth") or {}
        access = str(oauth.get("accessToken") or "")
        if access:
            fallback = access
        if _unix_deadline(oauth.get("expiresAt")) >= _now() + 90 and access:
            return access
        refresh = oauth.get("refreshToken")
        if not refresh:
            continue
        status, data = _http_json(
            CLAUDE_TOKEN_URL,
            {
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "claude-code/2.1.201",
            },
            data=json.dumps(
                {
                    "grant_type": "refresh_token",
                    "refresh_token": refresh,
                    "client_id": CLAUDE_CLIENT_ID,
                    "scope": "user:profile user:inference user:sessions:claude_code user:mcp_servers",
                }
            ).encode("utf-8"),
            method="POST",
        )
        if status != 200 or not isinstance(data, dict) or not data.get("access_token"):
            continue
        oauth["accessToken"] = data["access_token"]
        if data.get("refresh_token"):
            oauth["refreshToken"] = data["refresh_token"]
        if data.get("expires_in"):
            previous = oauth.get("expiresAt")
            unix = _now() + int(data["expires_in"])
            try:
                previous_n = float(previous)
            except (TypeError, ValueError):
                previous_n = 0
            oauth["expiresAt"] = int(unix * 1000) if previous_n > 10**12 else int(unix)
        raw["claudeAiOauth"] = oauth
        try:
            _claude_save(where, raw)
        except OSError:
            pass
        return str(oauth.get("accessToken") or "")
    return fallback


def _claude_window(node: Any, label: str) -> dict[str, Any]:
    if not isinstance(node, dict):
        return _window(None, None, label)
    return _window(
        node.get("utilization"),
        _parse_reset(node.get("resets_at")),
        label,
    )


def fetch_claude() -> dict[str, Any]:
    token = _claude_token()
    if not token:
        return _fail("claude", "claude_auth_missing")
    status, data = _http_json(
        CLAUDE_USAGE_URL,
        {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "anthropic-beta": "oauth-2025-04-20",
            "anthropic-version": "2023-06-01",
            "User-Agent": "claude-code/2.1.201",
        },
    )
    if status != 200 or not isinstance(data, dict):
        return _fail("claude", f"claude_http_{status}")
    session = _claude_window(data.get("five_hour"), "5h")
    weekly = _claude_window(data.get("seven_day"), "weekly")
    if session.get("used_percent") is None and weekly.get("used_percent") is None:
        return _fail("claude", "claude_usage_missing")
    return {
        "ok": True,
        "kind": "claude",
        "plan": "",
        "session": session,
        "weekly": weekly,
    }


def fetch_deepseek() -> dict[str, Any]:
    key = os.environ.get("DEEPSEEK_API_KEY", "").strip()
    if not key:
        return _fail("deepseek", "deepseek_key_missing")
    status, data = _http_json(
        DEEPSEEK_BALANCE_URL,
        {
            "Authorization": f"Bearer {key}",
            "Accept": "application/json",
            "User-Agent": "usage-rail/1",
        },
    )
    if status != 200 or not isinstance(data, dict):
        return _fail("deepseek", f"deepseek_http_{status}")
    infos = data.get("balance_infos") or []
    cny = next(
        (item for item in infos if isinstance(item, dict) and item.get("currency") == "CNY"),
        None,
    )
    if cny is None and infos and isinstance(infos[0], dict):
        cny = infos[0]
    if not isinstance(cny, dict):
        return _fail("deepseek", "deepseek_balance_missing")
    try:
        balance = float(cny.get("total_balance") or 0)
    except (TypeError, ValueError):
        return _fail("deepseek", "deepseek_balance_parse")
    return {
        "ok": True,
        "kind": "deepseek",
        "available": bool(data.get("is_available", True)),
        "balance_cny": round(balance, 2),
    }


def _keep_last(fresh: dict[str, Any], prev: dict[str, Any] | None) -> dict[str, Any]:
    if fresh.get("ok"):
        return fresh
    if isinstance(prev, dict) and prev.get("ok"):
        kept = dict(prev)
        kept["stale"] = True
        kept["last_error"] = fresh.get("error")
        return kept
    return fresh


def collect() -> dict[str, Any]:
    prev: dict[str, Any] | None = None
    if CACHE_PATH.exists():
        try:
            loaded = json.loads(CACHE_PATH.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                prev = loaded
        except Exception:
            prev = None
    snapshot = {
        "ok": True,
        "fetched_at": _iso_now(),
        "fetched_unix": int(_now()),
        "gpt": _keep_last(fetch_codex(), (prev or {}).get("gpt") if prev else None),
        "grok": _keep_last(fetch_grok(), (prev or {}).get("grok") if prev else None),
        "kimi": _keep_last(fetch_kimi(), (prev or {}).get("kimi") if prev else None),
        "claude": _keep_last(fetch_claude(), (prev or {}).get("claude") if prev else None),
        "deepseek": _keep_last(fetch_deepseek(), (prev or {}).get("deepseek") if prev else None),
    }
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = CACHE_PATH.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(CACHE_PATH)
    CACHE_PATH.chmod(0o600)
    return snapshot


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect subscription usage")
    parser.add_argument("--loop", type=int, default=0, help="Repeat every N seconds")
    parser.add_argument("--print", dest="do_print", action="store_true")
    args = parser.parse_args()
    while True:
        snap = collect()
        if args.do_print:
            print(json.dumps(snap, ensure_ascii=False, indent=2))
        if args.loop <= 0:
            return 0
        time.sleep(args.loop)


if __name__ == "__main__":
    raise SystemExit(main())
