#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/.build/release/UsageRail"
if [[ ! -x "$BIN" ]]; then
  echo "usage-rail binary missing: $BIN" >&2
  exit 1
fi
if codesign -dv "$BIN" 2>&1 | grep -q 'linker-signed'; then
  codesign --force --sign - "$BIN"
fi
if [[ -z "${HOME:-}" || "$HOME" == /var/empty ]]; then
  HOME="$(dscacheutil -q user -a name "$(stat -f %Su /dev/console)" | awk '/^dir:/{print $2; exit}')"
  export HOME
fi
export USAGE_RAIL_ROOT="$ROOT"
cd "$ROOT"
exec "$BIN"
