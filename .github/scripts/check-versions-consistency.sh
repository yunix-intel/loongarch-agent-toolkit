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
    "CODEX_CHANNEL=${CODEX_CHANNEL:-}" \
    "CODEX_VERSION=${CODEX_VERSION:-}" \
    "CODEX_SOURCE_VERSION=${CODEX_SOURCE_VERSION:-}" \
    "CODEX_SOURCE_URL=${CODEX_SOURCE_URL:-}" \
    "CODEX_SOURCE_SHA256=${CODEX_SOURCE_SHA256:-}" \
    "CODEX_LINK_DEFAULT=${CODEX_LINK_DEFAULT:-}" \
    "OPENCODE_VERSION=${OPENCODE_VERSION:-}" \
    "DSH_VERSION=${DSH_VERSION:-}" \
    "CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION:-}" \
    "CLAUDE_CODE_NPM_REGISTRY=${CLAUDE_CODE_NPM_REGISTRY:-}" \
    "CLAUDE_CODE_PREFIX=${CLAUDE_CODE_PREFIX:-}" \
    "CLAUDE_CODE_NODE=${CLAUDE_CODE_NODE:-}" \
    "CLAUDE_CODE_LINK_DEFAULT=${CLAUDE_CODE_LINK_DEFAULT:-}" \
    "ZCODE_TAG=${ZCODE_TAG:-}" \
    "ZCODE_VERSION=${ZCODE_VERSION:-}" \
    "ZCODE_CHANNEL=${ZCODE_CHANNEL:-}" \
    "ZCODE_CLI_URL=${ZCODE_CLI_URL:-}" \
    "ZCODE_CLI_SHA256=${ZCODE_CLI_SHA256:-}" \
    "ZCODE_DESKTOP_DEB_URL=${ZCODE_DESKTOP_DEB_URL:-}" \
    "ZCODE_DESKTOP_DEB_SHA256=${ZCODE_DESKTOP_DEB_SHA256:-}" \
    "ZCODE_STANDALONE_DEB_URL=${ZCODE_STANDALONE_DEB_URL:-}" \
    "ZCODE_STANDALONE_DEB_SHA256=${ZCODE_STANDALONE_DEB_SHA256:-}" \
    "ZCODE_LINK_DEFAULT=${ZCODE_LINK_DEFAULT:-}" \
    "CC_SWITCH_VERSION=${CC_SWITCH_VERSION:-}" \
    "CC_SWITCH_DEB_URL=${CC_SWITCH_DEB_URL:-}" \
    "CC_SWITCH_DEB_SHA256=${CC_SWITCH_DEB_SHA256:-}" ) > "$TMP/manifest.txt"

REQUIRED_KEYS=(NODE_VERSION CODEX_CHANNEL CODEX_VERSION CODEX_SOURCE_VERSION
    CODEX_SOURCE_URL CODEX_SOURCE_SHA256 CODEX_LINK_DEFAULT OPENCODE_VERSION
    DSH_VERSION CLAUDE_CODE_VERSION CLAUDE_CODE_NPM_REGISTRY
    CLAUDE_CODE_PREFIX CLAUDE_CODE_NODE CLAUDE_CODE_LINK_DEFAULT
    ZCODE_TAG ZCODE_VERSION ZCODE_CHANNEL
    ZCODE_CLI_URL ZCODE_CLI_SHA256 ZCODE_DESKTOP_DEB_URL
    ZCODE_DESKTOP_DEB_SHA256 ZCODE_STANDALONE_DEB_URL
    ZCODE_STANDALONE_DEB_SHA256 ZCODE_LINK_DEFAULT CC_SWITCH_VERSION
    CC_SWITCH_DEB_URL CC_SWITCH_DEB_SHA256)
# These keys must exist but may be empty.
EMPTY_OK=" CLAUDE_CODE_NODE CODEX_SOURCE_URL ZCODE_CLI_URL ZCODE_CLI_SHA256 ZCODE_DESKTOP_DEB_URL ZCODE_DESKTOP_DEB_SHA256 ZCODE_STANDALONE_DEB_URL ZCODE_STANDALONE_DEB_SHA256 "

for key in "${REQUIRED_KEYS[@]}"; do
    value=$(sed -n "s/^${key}=//p" "$TMP/manifest.txt")
    case "$EMPTY_OK" in
        *" $key "*) ;;
        *) [ -n "$value" ] || fail_msg "versions.env does not define $key" ;;
    esac
done

manifest_value() { sed -n "s/^$1=//p" "$TMP/manifest.txt"; }

case "$(manifest_value CODEX_CHANNEL)" in
    npm|source) ;;
    *) fail_msg "CODEX_CHANNEL must be npm or source" ;;
esac
case "$(manifest_value CODEX_LINK_DEFAULT)" in
    0|1) ;;
    *) fail_msg "CODEX_LINK_DEFAULT must be 0 or 1" ;;
esac
case "$(manifest_value ZCODE_CHANNEL)" in
    cli|desktop|standalone) ;;
    *) fail_msg "ZCODE_CHANNEL must be cli, desktop or standalone" ;;
esac
case "$(manifest_value ZCODE_LINK_DEFAULT)" in
    0|1) ;;
    *) fail_msg "ZCODE_LINK_DEFAULT must be 0 or 1" ;;
esac
case "$(manifest_value CLAUDE_CODE_LINK_DEFAULT)" in
    0|1) ;;
    *) fail_msg "CLAUDE_CODE_LINK_DEFAULT must be 0 or 1" ;;
esac
case "$(manifest_value CLAUDE_CODE_PREFIX)" in
    /*) ;;
    *) fail_msg "CLAUDE_CODE_PREFIX must be an absolute path" ;;
esac
cc_switch_sha=$(manifest_value CC_SWITCH_DEB_SHA256)
case "$cc_switch_sha" in
    *[!0-9a-fA-F]*) fail_msg "CC_SWITCH_DEB_SHA256 must be a hex digest" ;;
esac
[ "${#cc_switch_sha}" -eq 64 ] || fail_msg "CC_SWITCH_DEB_SHA256 must be 64 hex characters"
sha=$(manifest_value CODEX_SOURCE_SHA256)
case "$sha" in
    *[!0-9a-fA-F]*) fail_msg "CODEX_SOURCE_SHA256 must be a hex digest" ;;
esac
[ "${#sha}" -eq 64 ] || fail_msg "CODEX_SOURCE_SHA256 must be 64 hex characters"
[ "$(manifest_value ZCODE_VERSION)" = "$(manifest_value ZCODE_TAG)" ] \
    || fail_msg "ZCODE_VERSION must equal ZCODE_TAG"

case "$(manifest_value ZCODE_TAG)" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) fail_msg "ZCODE_TAG must look like vX.Y.Z" ;;
esac
case "$(manifest_value CC_SWITCH_VERSION)" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) fail_msg "CC_SWITCH_VERSION must look like vX.Y.Z" ;;
esac

# Asset URL/SHA pins are written together by the version watch.  A URL without
# a digest (or the reverse) means the manifest was edited half-way.
for pair in \
    "ZCODE_CLI_URL ZCODE_CLI_SHA256" \
    "ZCODE_DESKTOP_DEB_URL ZCODE_DESKTOP_DEB_SHA256" \
    "ZCODE_STANDALONE_DEB_URL ZCODE_STANDALONE_DEB_SHA256" \
    "CC_SWITCH_DEB_URL CC_SWITCH_DEB_SHA256"; do
    # shellcheck disable=SC2086
    set -- $pair
    url=$(manifest_value "$1")
    sha=$(manifest_value "$2")
    if [ -n "$url" ] && [ -z "$sha" ]; then
        fail_msg "$2 must be set when $1 is set"
    elif [ -z "$url" ] && [ -n "$sha" ]; then
        fail_msg "$1 must be set when $2 is set"
    fi
    case "$sha" in
        '') ;;
        *[!0-9a-fA-F]*) fail_msg "$2 must be a hex digest" ;;
        *) [ "${#sha}" -eq 64 ] || fail_msg "$2 must be 64 hex characters" ;;
    esac
done

# --- 2. Installer fallbacks -------------------------------------------------
# The block is machine-managed; the keys map to manifest keys by suffix.
extract_fallback() {
    sed -n "/BEGIN VERSION FALLBACKS/,/END VERSION FALLBACKS/p" "$INSTALLER" \
        | sed -n "s/^$1_DEFAULT=//p" | head -n 1 | tr -d '\r'
}

FALLBACK_KEYS=(NODE_VERSION CODEX_CHANNEL CODEX_VERSION CODEX_SOURCE_VERSION
    CODEX_SOURCE_URL CODEX_SOURCE_SHA256 CODEX_LINK_DEFAULT
    OPENCODE_VERSION DSH_VERSION)
EMPTY_OK_FALLBACK=" CODEX_SOURCE_URL "

for key in "${FALLBACK_KEYS[@]}"; do
    want=$(manifest_value "$key")
    got=$(extract_fallback "$key")
    case "$EMPTY_OK_FALLBACK" in
        *" $key "*) ;;
        *) [ -n "$got" ] || fail_msg "installer fallback ${key}_DEFAULT is missing" ;;
    esac
    if [ "$got" != "$want" ]; then
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
Codex (source):CODEX_SOURCE_VERSION
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
