#!/usr/bin/env bash
# Verify that the shared zcode-tauri source files are identical (ignoring line
# endings) between this repo and a loongarch-agent-builds checkout.  The two
# copies intentionally have different packaging variants; only the source set
# below must stay in sync.
#
# Usage: scripts/check-zcode-tauri-sync.sh /path/to/loongarch-agent-builds
set -euo pipefail

HERE=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BUILDS=${1:-}
[ -n "$BUILDS" ] || { echo "usage: $0 /path/to/loongarch-agent-builds" >&2; exit 2; }
[ -d "$BUILDS/vendor/zcode-tauri" ] || {
    echo "error: $BUILDS/vendor/zcode-tauri not found" >&2
    exit 2
}

SHARED=(
    src-tauri/src/main.rs
    src-tauri/tauri.conf.json
    src-tauri/Cargo.toml
    src-tauri/Cargo.lock
    src-tauri/.cargo/config.toml
    src-tauri/build.rs
    src-tauri/capabilities/default.json
    frontend/index.html
    packaging/gen_icons.py
    packaging/send_wm_delete.c
    icons/zcode-tauri.svg
)

fail=0
for f in "${SHARED[@]}"; do
    local_file="$HERE/zcode-tauri/$f"
    builds_file="$BUILDS/vendor/zcode-tauri/$f"
    if [ ! -f "$local_file" ] || [ ! -f "$builds_file" ]; then
        echo "MISSING: $f" >&2
        fail=1
        continue
    fi
    if ! diff -q <(tr -d '\r' < "$local_file") <(tr -d '\r' < "$builds_file") >/dev/null; then
        echo "DRIFT: $f" >&2
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "zcode-tauri shared sources drifted; keep them identical." >&2
    exit 1
fi
echo "OK: zcode-tauri shared sources match (line endings ignored)."
