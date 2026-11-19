#!/usr/bin/env python3
"""Read-only smoke check for the cache drawer.

Prints counts and fixed status words only. It does not print log lines,
message text, URLs, hashes, request ids, or paths. It does not write files,
open a network socket, or call a model.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


ALLOWED_STATUS = {
    "not-configured",
    "waiting",
    "readable",
    "missing",
    "unreadable",
    "mode-ok",
    "mode-loose",
}


def empty_report() -> dict:
    return {
        "config": "not-configured",
        "config_mode": "missing",
        "session_pointer": "missing",
        "transcript": "missing",
        "vertex_log": "missing",
        "fingerprint_log": "missing",
        "siwc_log": "missing",
        "user_turns": 0,
        "completions": 0,
        "rate_limit_without_usage": 0,
        "session_cached_present": 0,
        "session_cached_zero": 0,
        "session_cached_missing": 0,
        "vertex_prefix": 0,
        "vertex_usage": 0,
        "vertex_cached_present": 0,
        "vertex_cached_zero": 0,
        "vertex_cached_missing": 0,
        "vertex_status_429": 0,
        "fingerprint_rows": 0,
        "siwc_rows": 0,
        "siwc_cached_zero": 0,
        "skipped_lines": 0,
    }


def config_from_env() -> tuple[str | None, str]:
    runtime = os.environ.get("NOXBUILD_RUNTIME", "").strip()
    if runtime:
        return runtime, "missing"
    home = Path.home()
    path = home / ".cache" / "usage-rail" / "cache-companion.json"
    if not path.is_file():
        return None, "missing"
    mode = "mode-ok" if (path.stat().st_mode & 0o777) == 0o600 else "mode-loose"
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None, mode
    root = payload.get("runtimeRoot") if isinstance(payload, dict) else None
    if not isinstance(root, str) or not root.strip():
        return None, mode
    return root.strip(), mode


def file_state(path: Path) -> str:
    if not path.exists():
        return "missing"
    if not os.access(path, os.R_OK):
        return "unreadable"
    return "readable"


def inside(root: Path, candidate: Path) -> bool:
    try:
        root_resolved = root.resolve()
        candidate_resolved = candidate.resolve()
    except OSError:
        return False
    return candidate_resolved == root_resolved or root_resolved in candidate_resolved.parents


def iter_lines(path: Path):
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            yield line


def tally_updates(path: Path, report: dict) -> None:
    seen: set[int] = set()
    for raw in iter_lines(path):
        text = raw.strip()
        if not text:
            continue
        try:
            obj = json.loads(text)
        except Exception:
            report["skipped_lines"] += 1
            continue
        if not isinstance(obj, dict):
            continue
        method = obj.get("method")
        if method not in {"session/update", "_x.ai/session/update"}:
            continue
        params = obj.get("params")
        update = params.get("update") if isinstance(params, dict) else None
        if not isinstance(update, dict):
            continue
        kind = update.get("sessionUpdate")
        if kind == "user_message_chunk":
            meta = update.get("_meta") if isinstance(update.get("_meta"), dict) else {}
            index = meta.get("promptIndex")
            if isinstance(index, bool) or not isinstance(index, int):
                continue
            seen.add(index)
        elif kind == "turn_completed":
            report["completions"] += 1
            usage = update.get("usage") if isinstance(update.get("usage"), dict) else None
            stop = update.get("stop_reason")
            if usage is None:
                if stop == "rate_limit":
                    report["rate_limit_without_usage"] += 1
                continue
            if "cachedReadTokens" not in usage or usage.get("cachedReadTokens") is None:
                report["session_cached_missing"] += 1
            elif usage.get("cachedReadTokens") == 0:
                report["session_cached_present"] += 1
                report["session_cached_zero"] += 1
            elif isinstance(usage.get("cachedReadTokens"), int):
                report["session_cached_present"] += 1
    report["user_turns"] = len(seen)


def tally_vertex(path: Path, report: dict) -> None:
    for raw in iter_lines(path):
        text = raw.strip()
        if not text:
            continue
        try:
            obj = json.loads(text)
        except Exception:
            report["skipped_lines"] += 1
            continue
        if not isinstance(obj, dict) or obj.get("layer") != "vertex_final_outbound":
            continue
        event = obj.get("event")
        if event == "prefix":
            report["vertex_prefix"] += 1
        elif event == "usage":
            report["vertex_usage"] += 1
            if obj.get("status") == 429:
                report["vertex_status_429"] += 1
            cached = obj.get("cached_tokens", None)
            if "cached_tokens" not in obj or cached is None:
                report["vertex_cached_missing"] += 1
            elif cached == 0:
                report["vertex_cached_present"] += 1
                report["vertex_cached_zero"] += 1
            elif isinstance(cached, int):
                report["vertex_cached_present"] += 1


def tally_fingerprint(path: Path, report: dict) -> None:
    for raw in iter_lines(path):
        text = raw.strip()
        if not text:
            continue
        try:
            obj = json.loads(text)
        except Exception:
            report["skipped_lines"] += 1
            continue
        if isinstance(obj, dict):
            report["fingerprint_rows"] += 1


def tally_siwc(path: Path, report: dict) -> None:
    marker = "request_id="
    for raw in iter_lines(path):
        if "siwc_proxy:" not in raw or "POST /v1/responses" not in raw or marker not in raw:
            continue
        report["siwc_rows"] += 1
        cached_token = " cached=0 "
        if cached_token in f" {raw}":
            report["siwc_cached_zero"] += 1


def safe_dump(report: dict) -> str:
    cleaned = {}
    for key, value in report.items():
        if isinstance(value, bool):
            cleaned[key] = value
        elif isinstance(value, int) and not isinstance(value, bool):
            cleaned[key] = value
        elif isinstance(value, str) and value in ALLOWED_STATUS:
            cleaned[key] = value
        else:
            cleaned[key] = "skipped"
    text = json.dumps(cleaned, ensure_ascii=True, sort_keys=True)
    lowered = text.lower()
    if "http://" in lowered or "https://" in lowered or "secret" in lowered:
        return json.dumps({"error": "refused"})
    return text


def main() -> int:
    report = empty_report()
    root_text, config_mode = config_from_env()
    report["config_mode"] = config_mode
    if not root_text:
        report["config"] = "not-configured"
        sys.stdout.write(safe_dump(report) + "\n")
        return 0
    report["config"] = "readable"
    root = Path(root_text)
    pointer = root / "state" / "active_session.json"
    report["session_pointer"] = file_state(pointer)
    transcript: Path | None = None
    if report["session_pointer"] == "readable":
        try:
            payload = json.loads(pointer.read_text(encoding="utf-8"))
        except Exception:
            report["session_pointer"] = "unreadable"
            payload = None
        if isinstance(payload, dict):
            raw_path = payload.get("transcript_path")
            if isinstance(raw_path, str) and raw_path.strip():
                candidate = Path(raw_path.strip())
                if inside(root, candidate):
                    transcript = candidate
                    report["transcript"] = file_state(candidate)
                else:
                    report["transcript"] = "unreadable"
    home = Path.home()
    vertex = Path(os.environ.get("NOX_VERTEX_OBSERVE_LOG", str(home / "Library" / "Logs" / "nox-vertex-observe.jsonl")))
    finger = Path(os.environ.get("NOX_PREFIX_FINGERPRINT_LOG", str(home / "Library" / "Logs" / "nox-prefix-fingerprints.jsonl")))
    siwc = Path(os.environ.get("NOX_SIWC_LOG", str(home / "Library" / "Logs" / "nox-openai-siwc.log")))
    report["vertex_log"] = file_state(vertex)
    report["fingerprint_log"] = file_state(finger)
    report["siwc_log"] = file_state(siwc)
    if transcript is not None and report["transcript"] == "readable":
        tally_updates(transcript, report)
    if report["vertex_log"] == "readable":
        tally_vertex(vertex, report)
    if report["fingerprint_log"] == "readable":
        tally_fingerprint(finger, report)
    if report["siwc_log"] == "readable":
        tally_siwc(siwc, report)
    sys.stdout.write(safe_dump(report) + "\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BrokenPipeError:
        raise SystemExit(0)
    except Exception:
        sys.stdout.write(json.dumps({"error": "failed"}) + "\n")
        raise SystemExit(1)
