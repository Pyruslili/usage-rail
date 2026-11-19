#!/bin/sh
# Apply the cache-drawer increment onto an existing usage-rail checkout.
# Checks preimage SHA256, copies allowlisted files, and verifies postimage SHA256.
# Does not build, install, restart, read local.py, or replace collect.py.
set -eu

usage() {
    echo "usage: apply-cache-drawer.sh --root <usage-rail-checkout> [--apply]" >&2
    echo "Without --apply the script only checks hashes and prints the plan." >&2
    exit 2
}

ROOT=""
APPLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --root)
            ROOT=${2:-}
            shift 2
            ;;
        --apply)
            APPLY=1
            shift
            ;;
        *)
            usage
            ;;
    esac
done
[ -n "$ROOT" ] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PAYLOAD=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
MANIFEST="$PAYLOAD/MANIFEST.json"
FILES="$PAYLOAD/files"
[ -f "$MANIFEST" ] || {
    echo "missing manifest" >&2
    exit 1
}
[ -d "$FILES" ] || {
    echo "missing files directory" >&2
    exit 1
}

hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

python3 - "$MANIFEST" "$ROOT" "$FILES" "$APPLY" <<'PY'
import hashlib, json, os, shutil, sys, time
from pathlib import Path

manifest_path, root_text, files_text, apply_flag = sys.argv[1:]
apply = apply_flag == "1"
root = Path(root_text).resolve()
files = Path(files_text).resolve()
manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))

forbidden = {
    "mac/collect.py",
    "mac/local.py",
    "mac/vertex_status.py",
    "mac/launch-agent.sh",
    "mac/launch.sh",
    "mac/install/com.usage-rail.plist.example",
}
allow = set(manifest["preimage"]) | set(manifest["new_files"])
if forbidden & allow:
    sys.exit("manifest names a forbidden path")
for rel in list(manifest["preimage"]) + list(manifest["new_files"]):
    if not rel.startswith("mac/") or ".." in Path(rel).parts:
        sys.exit(f"path not allowlisted: {rel}")

def digest(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()

problems = []
for rel, expected in manifest["untouched"].items():
    path = root / rel
    if rel == "mac/local.py":
        if path.exists():
            print("local.py present; left unread")
        else:
            print("local.py absent; left absent")
        continue
    if not path.is_file():
        problems.append(f"missing untouched file {rel}")
        continue
    actual = digest(path)
    if actual != expected:
        problems.append(f"untouched hash mismatch {rel}")

for rel, expected in manifest["preimage"].items():
    path = root / rel
    post = manifest["postimage"][rel]
    if not path.is_file():
        problems.append(f"missing {rel}")
        continue
    actual = digest(path)
    if actual == post:
        print(f"already applied {rel}")
    elif actual != expected:
        problems.append(f"preimage mismatch {rel}")

for rel, expected in manifest["new_files"].items():
    src = files / rel
    dest = root / rel
    if not src.is_file() or digest(src) != expected:
        problems.append(f"payload mismatch {rel}")
        continue
    if dest.exists() and digest(dest) != expected:
        problems.append(f"destination differs {rel}")

if problems:
    print("refusing to write:")
    for item in problems:
        print(f"  {item}")
    sys.exit(1)

if not apply:
    print("hash check passed; re-run with --apply to copy files")
    sys.exit(0)

stamp = time.strftime("%Y%m%d-%H%M%S")
backup = Path.home() / ".cache" / "usage-rail" / "cache-drawer-backups" / stamp
backup.mkdir(parents=True, exist_ok=False)
for rel in manifest["preimage"]:
    src = root / rel
    dest = backup / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)

for rel, expected in manifest["postimage"].items():
    src = files / rel
    dest = root / rel
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dest)
    os.chmod(dest, 0o644)
    if digest(dest) != expected:
        sys.exit(f"postimage mismatch after copy {rel}")

print(f"backup {backup}")
print("applied cache-drawer files")
print("next, on this Mac, from the checkout:")
print("  cd mac && swift test")
print("  cd mac && swift build -c release --product UsageRail")
print("do not launchctl, and do not replace the running binary, until those pass")
PY
