#!/usr/bin/env bash
# check-versions-consistency.sh
#
# Fail CI when the three copies of the agent version pins disagree:
#   1. install/versions.env                    (single source of truth)
#   2. install/install-loongarch-agents.sh    (BEGIN/END VERSION FALLBACKS)
#   3. README.md                              (agent-versions block)
#
# No network access, no jq.  Run from the repository root.

# Backticks inside single-quoted sed expressions are literal, not substitution.
# shellcheck disable=SC2016
set -euo pipefail

ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)}
MANIFEST=${MANIFEST:-$ROOT/install/versions.env}
INSTALLER=${INSTALLER:-$ROOT/install/install-loongarch-agents.sh}
README=${README:-$ROOT/README.md}

fail=0
fail_msg() { printf 'FAIL: %s\n' "$*" >&2; fail=1; }

need_file() {
    [ -f "$1" ] || {
        printf 'FAIL: missing file: %s\n' "$1" >&2
        exit 1
    }
}

need_file "$MANIFEST"
need_file "$INSTALLER"
need_file "$README"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/versions-consistency.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

# Load the manifest in a subshell so its values cannot leak into other reads.
# shellcheck disable=SC1090,SC1091
( . "$MANIFEST" && printf '%s\n' \
    "NODE_VERSION=${NODE_VERSION:-}" \
    "CODEX_VERSION=${CODEX_VERSION:-}" \
    "OPENCODE_VERSION=${OPENCODE_VERSION:-}" \
    "DSH_VERSION=${DSH_VERSION:-}" \
    "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION:-}" \
    "ZCODE_TAG=${ZCODE_TAG:-}" \
    "CC_SWITCH_VERSION=${CC_SWITCH_VERSION:-}" ) > "$TMP/manifest.txt"

REQUIRED_KEYS=(NODE_VERSION CODEX_VERSION OPENCODE_VERSION DSH_VERSION CLAUDE_CODE_VERSION ZCODE_TAG CC_SWITCH_VERSION)
for key in "${REQUIRED_KEYS[@]}"; do
    value=$(sed -n "s/^${key}=//p" "$TMP/manifest.txt")
    [ -n "$value" ] || fail_msg "versions.env does not define $key"
done

manifest_value() { sed -n "s/^$1=//p" "$TMP/manifest.txt"; }

# --- 2. Installer fallbacks -------------------------------------------------
# The block is machine-managed; the keys map to manifest keys by suffix.
extract_fallback() {
    sed -n "/BEGIN VERSION FALLBACKS/,/END VERSION FALLBACKS/p" "$INSTALLER" \
        | sed -n "s/^$1_DEFAULT=//p" | head -n 1 | tr -d '\r'
}

for key in NODE_VERSION CODEX_VERSION OPENCODE_VERSION DSH_VERSION; do
    want=$(manifest_value "$key")
    got=$(extract_fallback "$key")
    if [ -z "$got" ]; then
        fail_msg "installer fallback ${key}_DEFAULT is missing"
    elif [ "$got" != "$want" ]; then
        fail_msg "installer fallback ${key}_DEFAULT=${got} != versions.env ${key}=${want}"
    fi
done

# --- 3. README table --------------------------------------------------------
sed -n '/<!-- agent-versions:begin -->/,/<!-- agent-versions:end -->/p' "$README" \
    > "$TMP/readme-block.md"

[ -s "$TMP/readme-block.md" ] || fail_msg "README is missing the agent-versions block"

# Tool label as written in the README -> manifest key.
readme_rows="Node.js:NODE_VERSION
Codex:CODEX_VERSION
OpenCode:OPENCODE_VERSION
DSH:DSH_VERSION
Claude Code:CLAUDE_CODE_VERSION
ZCode:ZCODE_TAG
cc-switch:CC_SWITCH_VERSION"

while IFS=: read -r label key; do
    [ -n "$label" ] || continue
    line=$(grep -F "| $label |" "$TMP/readme-block.md" || true)
    if [ -z "$line" ]; then
        fail_msg "README table has no row for $label"
        continue
    fi
    # Second cell, first backticked value: | Tool | `1.2.3` | note |
    cell=$(printf '%s\n' "$line" | awk -F'|' '{print $3}')
    readme_ver=$(printf '%s\n' "$cell" | sed -n 's/.*`\([^`]*\)`.*/\1/p')
    want=$(manifest_value "$key")
    if [ -z "$readme_ver" ]; then
        fail_msg "README row for $label has no backticked version"
    elif [ "$readme_ver" != "$want" ]; then
        fail_msg "README $label=${readme_ver} != versions.env ${key}=${want}"
    fi
done <<EOF
$readme_rows
EOF

if [ "$fail" -ne 0 ]; then
    printf '\nVersion pins are out of sync. Update versions.env, the installer\n' >&2
    printf 'fallback block and the README agent-versions table together.\n' >&2
    exit 1
fi

printf 'OK: versions.env, installer fallbacks and README table agree.\n'
for key in "${REQUIRED_KEYS[@]}"; do
    printf '  %-20s %s\n' "$key" "$(manifest_value "$key")"
done
