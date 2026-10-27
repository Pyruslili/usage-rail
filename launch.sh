#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
/usr/bin/python3 "$ROOT/collect.py"
BIN="$ROOT/.build/release/UsageRail"
if [[ ! -x "$BIN" ]]; then
  swift build -c release --product UsageRail
fi
if codesign -dv "$BIN" 2>&1 | grep -q 'linker-signed'; then
  codesign --force --sign - "$BIN"
fi
export USAGE_RAIL_ROOT="$ROOT"
UID_NUM="$(id -u)"
LABEL="com.usage-rail"
if launchctl print "gui/${UID_NUM}/${LABEL}" >/dev/null 2>&1; then
  exec launchctl kickstart -k "gui/${UID_NUM}/${LABEL}"
fi
pkill -f "$BIN" 2>/dev/null || true
exec "$BIN"
