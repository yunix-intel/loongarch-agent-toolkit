#!/usr/bin/env bash
# check-agent-versions.sh
#
# Compute the *selected* version of every agent (the newest version that is
# actually usable on LoongArch), compare it with install/versions.env, and
# prepare the issue / auto-alignment PR payloads.
#
# Outputs (in the current directory by default):
#   version-table.md  Markdown table for the job summary and the issue
#   issue-body.md     Issue body used by agent-version-watch.yml
#   changes.md        PR body; only written when a selected version changed
#
# When GITHUB_OUTPUT is set:
#   has_changes=true|false
#   needs_issue=true
#
# The script may update install/versions.env, the installer fallback block and
# the README agent-versions block in the working tree when a version changed.
# It never commits, pushes, installs or publishes; the workflow does the PR.

# Backticks inside single-quoted strings are Markdown, not command substitution.
# shellcheck disable=SC2016
set -euo pipefail

ROOT=${ROOT:-$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)}
MANIFEST=${MANIFEST:-$ROOT/install/versions.env}
INSTALLER=${INSTALLER:-$ROOT/install/install-loongarch-agents.sh}
README=${README:-$ROOT/README.md}
OUT_TABLE=${OUT_TABLE:-version-table.md}
OUT_BODY=${OUT_BODY:-issue-body.md}
OUT_CHANGES=${OUT_CHANGES:-changes.md}

UPSTREAM_REGISTRY=${UPSTREAM_REGISTRY:-https://registry.npmjs.org}
LOONG_REGISTRY=${LOONG_REGISTRY:-https://registry.loongnix.cn:5873}
ZCODE_REPO=${ZCODE_REPO:-zai-org/ZCode}
CCSWITCH_REPO=${CCSWITCH_REPO:-farion1231/cc-switch}
BUILDS_REPO=${BUILDS_REPO:-yunix-intel/loongarch-agent-builds}
TODAY=${TODAY:-$(date -u +%Y-%m-%d)}
TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}
# Only an explicitly supplied GH_TOKEN (AUTO_ALIGN_TOKEN in CI) may read the
# private builds repo.  The repo-scoped GITHUB_TOKEN cannot see it, so do not
# use it for the source-build query.
BUILDS_TOKEN=${GH_TOKEN:-}

warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need curl
need sort
need sed
need awk
need grep

if command -v python3 >/dev/null 2>&1 && python3 -I -c 'import sys' >/dev/null 2>&1; then
    PYTHON=python3
elif command -v python >/dev/null 2>&1 && python -I -c 'import sys' >/dev/null 2>&1; then
    PYTHON=python
else
    die "missing required command: python3 (or python)"
fi

[ -f "$MANIFEST" ] || die "version manifest not found: $MANIFEST"
[ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"
[ -f "$README" ] || die "README not found: $README"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-version-watch.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------

manifest_value() {
    sed -n "s/^[[:space:]]*$1=//p" "$MANIFEST" | head -n 1 | tr -d '\r'
}

fetch() {
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 180 "$1" -o "$2"
}

# Print all keys of the "versions" object, one per line.
list_versions() {
    "$PYTHON" -I - "$1" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
for key in data.get("versions", {}):
    print(key)
PY
}

# Print dist-tags.<tag> (default latest).
dist_tag() {
    "$PYTHON" -I - "$1" "${2:-latest}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(data.get("dist-tags", {}).get(sys.argv[2], ""))
PY
}

# npm upstream latest (URL-encoded package name).
npm_latest() {
    local pkg=$1 file
    file="$TMP/npm-$(printf '%s' "$pkg" | tr -c 'A-Za-z0-9' '_').json"
    if fetch "$UPSTREAM_REGISTRY/$pkg/latest" "$file"; then
        "$PYTHON" -I - "$file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    print(json.load(fh).get("version", ""))
PY
    else
        warn "failed to query $UPSTREAM_REGISTRY/$pkg/latest"
        printf ''
    fi
}

# Highest @openai/codex version with a -linux-loong64 build.
codex_loong_latest() {
    local file="$TMP/codex-loong.json"
    if ! fetch "$LOONG_REGISTRY/@openai%2Fcodex" "$file"; then
        warn "failed to query $LOONG_REGISTRY/@openai%2Fcodex"
        printf ''
        return 0
    fi
    list_versions "$file" \
        | grep -- '-linux-loong64$' \
        | sed 's/-linux-loong64$//' \
        | sort -V | tail -n 1 || true
}

opencode_loong_latest() {
    local file="$TMP/opencode-loong.json"
    if ! fetch "$LOONG_REGISTRY/opencode-linux-loong64" "$file"; then
        warn "failed to query $LOONG_REGISTRY/opencode-linux-loong64"
        printf ''
        return 0
    fi
    dist_tag "$file" latest
}

dsh_loong_latest() {
    local file="$TMP/dsh-loong.json"
    if ! fetch "$LOONG_REGISTRY/@deepseek-ai%2Fdsh" "$file"; then
        warn "failed to query $LOONG_REGISTRY/@deepseek-ai%2Fdsh"
        printf ''
        return 0
    fi
    dist_tag "$file" latest
}

# Optional: highest source-built Codex release in the private builds repo.
# Uses GH_TOKEN/GITHUB_TOKEN; a token without access simply yields nothing.
gh_api() {
    if [ -n "$TOKEN" ]; then
        GH_TOKEN="$TOKEN" gh api "$@"
    else
        gh api "$@"
    fi
}

gh_builds_api() {
    GH_TOKEN="$BUILDS_TOKEN" gh api "$@"
}

# Newest source-built Codex release in the private builds repo.
# Prints: version <TAB> asset API URL <TAB> sha256 <TAB> asset_name
# Draft releases are included when the token can see them.  A token without
# access yields nothing; the caller reports "private" instead of guessing.
# The API asset URL (not browser_download_url) is used because draft releases
# are only downloadable through the API with Accept: application/octet-stream.
codex_source_release() {
    [ -n "$BUILDS_TOKEN" ] || return 0
    command -v gh >/dev/null 2>&1 || return 0
    gh_builds_api "repos/$BUILDS_REPO/releases?per_page=100" \
        --paginate \
        --jq '.[] | .tag_name as $tag
              | .assets[]?
              | select(.name | test("codex.*loongarch64[.]tar[.]gz$"))
              | [$tag, .url, (.digest // ""), .name]
              | @tsv' 2>/dev/null \
        | while IFS="$(printf '\t')" read -r tag url digest name; do
            version=$(printf '%s' "$tag" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | tail -n 1)
            [ -n "$version" ] || continue
            sha=${digest#sha256:}
            case "$sha" in
                *[!0-9a-fA-F]*) continue ;;
            esac
            [ "${#sha}" -eq 64 ] || continue
            printf '%s\t%s\t%s\t%s\n' "$version" "$url" "$sha" "$name"
        done \
        | sort -V | tail -n 1 || true
}

gh_tags() {
    command -v gh >/dev/null 2>&1 || return 0
    gh_api "repos/$1/tags?per_page=100" \
        --paginate --jq '.[].name' 2>/dev/null || true
}

gh_latest_release() {
    command -v gh >/dev/null 2>&1 || return 0
    gh_api "repos/$1/releases/latest" \
        --jq '.tag_name' 2>/dev/null || true
}

# Does the npm tarball for $1 still ship package/cli.js?
# 0 = yes, 1 = no (404), 2 = unknown (network/CDN failure).
http_status() {
    local url=$1 code attempt=0
    while [ "$attempt" -lt 2 ]; do
        attempt=$(( attempt + 1 ))
        code=$(curl -sIL --max-time 12 -o /dev/null -w '%{http_code}' "$url" || true)
        case "$code" in
            200|404) printf '%s' "$code"; return 0 ;;
        esac
        sleep 1
    done
    printf '%s' "${code:-000}"
}

# unpkg and jsDelivr both mirror npm; a 200 or 404 from either is definitive.
# Ask unpkg first (jsDelivr rate-limits HEAD requests) and only fall back when
# the answer is neither 200 nor 404.
claude_has_cli() {
    local c1 c2
    c1=$(http_status "https://unpkg.com/@anthropic-ai/claude-code@$1/cli.js")
    case "$c1" in
        200) return 0 ;;
        404) return 1 ;;
    esac
    c2=$(http_status "https://cdn.jsdelivr.net/npm/@anthropic-ai/claude-code@$1/cli.js")
    case "$c2" in
        200) return 0 ;;
        404) return 1 ;;
    esac
    return 2
}

# Newest Claude Code release whose tarball still contains cli.js.
# Presence is monotonic (2.1.112 has it, 2.1.113+ are native-only), so binary
# search over the sorted stable versions costs ~log2(N) HEAD requests.
claude_js_latest() {
    local file="$TMP/claude-code.json" vers=() lo hi mid ans=-1 rc
    if ! fetch "$UPSTREAM_REGISTRY/@anthropic-ai%2Fclaude-code" "$file"; then
        warn "failed to query $UPSTREAM_REGISTRY/@anthropic-ai%2Fclaude-code"
        printf ''
        return 0
    fi
    mapfile -t vers < <(list_versions "$file" \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)
    if [ "${#vers[@]}" -eq 0 ]; then
        warn "no stable Claude Code versions found"
        printf ''
        return 0
    fi
    lo=0
    hi=$(( ${#vers[@]} - 1 ))
    while [ "$lo" -le "$hi" ]; do
        mid=$(( (lo + hi) / 2 ))
        rc=0
        claude_has_cli "${vers[$mid]}" || rc=$?
        case "$rc" in
            0) ans=$mid; lo=$(( mid + 1 )) ;;
            1) hi=$(( mid - 1 )) ;;
            *)
                warn "could not determine cli.js presence for ${vers[$mid]}"
                printf ''
                return 0
                ;;
        esac
    done
    if [ "$ans" -lt 0 ]; then
        warn "could not find any Claude Code version shipping cli.js"
        printf ''
        return 0
    fi
    # Guard against a transient 404 breaking the monotonic search: the next
    # newer version must really be missing cli.js.
    if [ $(( ans + 1 )) -lt "${#vers[@]}" ]; then
        rc=0
        claude_has_cli "${vers[$(( ans + 1 ))]}" || rc=$?
        if [ "$rc" -ne 1 ]; then
            warn "cli.js boundary check failed at ${vers[$(( ans + 1 ))]}"
            printf ''
            return 0
        fi
    fi
    printf '%s' "${vers[$ans]}"
}

version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]
}

version_max() {
    local a=$1 b=$2
    if [ -z "$a" ]; then printf '%s' "$b"; return; fi
    if [ -z "$b" ]; then printf '%s' "$a"; return; fi
    if version_gt "$a" "$b"; then printf '%s' "$a"; else printf '%s' "$b"; fi
}

show_ver() { if [ -n "$1" ]; then printf '`%s`' "$1"; else printf '-'; fi; }

# status(pin, selected, upstream, lag_status)
status_of() {
    local pin=$1 sel=$2 up=$3 lag=$4
    if [ -z "$sel" ]; then
        printf 'query-failed'
    elif version_gt "$sel" "$pin"; then
        printf 'update-available'
    elif [ "$pin" = "$sel" ]; then
        if [ -n "$up" ] && version_gt "$up" "$sel"; then
            printf '%s' "$lag"
        else
            printf 'up-to-date'
        fi
    else
        printf 'pinned-ahead'
    fi
}

# --------------------------------------------------------------------------
# query
# --------------------------------------------------------------------------

CODEX_PIN=$(manifest_value CODEX_VERSION)
CODEX_CHANNEL_PIN=$(manifest_value CODEX_CHANNEL)
CODEX_SOURCE_PIN=$(manifest_value CODEX_SOURCE_VERSION)
CODEX_SOURCE_URL_PIN=$(manifest_value CODEX_SOURCE_URL)
CODEX_SOURCE_SHA_PIN=$(manifest_value CODEX_SOURCE_SHA256)
OPENCODE_PIN=$(manifest_value OPENCODE_VERSION)
DSH_PIN=$(manifest_value DSH_VERSION)
CLAUDE_PIN=$(manifest_value CLAUDE_CODE_VERSION)
ZCODE_PIN=$(manifest_value ZCODE_TAG)
CCSWITCH_PIN=$(manifest_value CC_SWITCH_VERSION)

CODEX_UP=$(npm_latest '@openai%2Fcodex')
OPENCODE_UP=$(npm_latest 'opencode-ai')
DSH_UP=$(npm_latest '@deepseek-ai%2Fdsh')
CLAUDE_UP=$(npm_latest '@anthropic-ai%2Fclaude-code')

CODEX_LOONG=$(codex_loong_latest)
CODEX_SOURCE_TSV=$(codex_source_release)
CODEX_SOURCE_NEW=$(printf '%s' "$CODEX_SOURCE_TSV" | cut -f1)
CODEX_SOURCE_NEW_URL=$(printf '%s' "$CODEX_SOURCE_TSV" | cut -f2)
CODEX_SOURCE_NEW_SHA=$(printf '%s' "$CODEX_SOURCE_TSV" | cut -f3)
CODEX_SOURCE_NEW_NAME=$(printf '%s' "$CODEX_SOURCE_TSV" | cut -f4)
OPENCODE_LOONG=$(opencode_loong_latest)
DSH_LOONG=$(dsh_loong_latest)
CLAUDE_JS=$(claude_js_latest)

ZCODE_RELEASE=$(gh_latest_release "$ZCODE_REPO")
ZCODE_TAGS=$(gh_tags "$ZCODE_REPO" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
CCSWITCH_RELEASE=$(gh_latest_release "$CCSWITCH_REPO")

# The npm channel stays the default and keeps tracking the loong64 port; the
# source build is reported separately unless CODEX_CHANNEL=source.
CODEX_SEL=$CODEX_LOONG
if [ "$CODEX_CHANNEL_PIN" = "source" ]; then
    CODEX_SEL=${CODEX_SOURCE_NEW:-$CODEX_SOURCE_PIN}
fi
OPENCODE_SEL=$OPENCODE_LOONG
DSH_SEL=$DSH_LOONG
CLAUDE_SEL=$CLAUDE_JS
ZCODE_SEL=$ZCODE_TAGS
CCSWITCH_SEL=$CCSWITCH_RELEASE

if [ "$CODEX_CHANNEL_PIN" = "source" ]; then
    if [ -z "$CODEX_SEL" ]; then
        CODEX_STATUS='query-failed'
    elif version_gt "$CODEX_SEL" "$CODEX_SOURCE_PIN"; then
        CODEX_STATUS='update-available'
    else
        CODEX_STATUS='source-selected'
    fi
else
    CODEX_STATUS=$(status_of "$CODEX_PIN" "$CODEX_SEL" "$CODEX_UP" waiting-for-loong64-port)
fi
OPENCODE_STATUS=$(status_of "$OPENCODE_PIN" "$OPENCODE_SEL" "$OPENCODE_UP" waiting-for-loong64-port)
DSH_STATUS=$(status_of "$DSH_PIN" "$DSH_SEL" "$DSH_UP" waiting-upstream-sync)
CLAUDE_STATUS=$(status_of "$CLAUDE_PIN" "$CLAUDE_SEL" "$CLAUDE_UP" native-only)
CCSWITCH_STATUS=$(status_of "$CCSWITCH_PIN" "$CCSWITCH_SEL" "$CCSWITCH_RELEASE" upstream-ahead)

if [ -n "$CODEX_SOURCE_NEW" ]; then
    if [ "$CODEX_CHANNEL_PIN" = "source" ]; then
        CODEX_SOURCE_STATUS='selected'
    else
        CODEX_SOURCE_STATUS='source-available'
    fi
elif [ -n "$CODEX_SOURCE_PIN" ]; then
    if [ -n "$BUILDS_TOKEN" ]; then
        CODEX_SOURCE_STATUS='source-unavailable'
    else
        CODEX_SOURCE_STATUS='source-private'
    fi
else
    CODEX_SOURCE_STATUS='unset'
fi

# ZCode is selected from tags, while "upstream" is the GitHub release.  Report
# a release that lags its own tags even when the pin is already correct.
if [ -z "$ZCODE_SEL" ]; then
    ZCODE_STATUS='query-failed'
elif version_gt "$ZCODE_SEL" "$ZCODE_PIN"; then
    ZCODE_STATUS='update-available'
elif [ -n "$ZCODE_RELEASE" ] && [ "$ZCODE_RELEASE" != "$ZCODE_SEL" ] \
    && ! version_gt "$ZCODE_RELEASE" "$ZCODE_SEL"; then
    ZCODE_STATUS='tag-ahead-of-release'
else
    ZCODE_STATUS='up-to-date'
fi

CODEX_NOTE='龙芯 loong64 可用最新版'
if [ "$CODEX_CHANNEL_PIN" = "source" ]; then
    CODEX_NOTE="源码通道 ${CODEX_SOURCE_PIN}"
elif [ -n "$CODEX_SOURCE_NEW" ]; then
    CODEX_NOTE="npm 默认；source ${CODEX_SOURCE_NEW} 可选"
fi

# --------------------------------------------------------------------------
# table
# --------------------------------------------------------------------------

{
    printf '| 工具 | upstream | 平台/loong64 可用 | selected | 状态 |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    printf '| Codex (`@openai/codex`) | %s | %s | %s | `%s` |\n' \
        "$(show_ver "$CODEX_UP")" "$(show_ver "$CODEX_LOONG")" \
        "$(show_ver "$CODEX_SEL")" "$CODEX_STATUS"
    if [ -n "$CODEX_SOURCE_NEW" ]; then
        SOURCE_PLATFORM='builds release'
    elif [ -n "$CODEX_SOURCE_URL_PIN" ]; then
        SOURCE_PLATFORM='URL set'
    else
        SOURCE_PLATFORM='private'
    fi
    printf '| Codex (source) | %s | %s | %s | `%s` |\n' \
        "$(show_ver "${CODEX_SOURCE_NEW:-$CODEX_SOURCE_PIN}")" "$SOURCE_PLATFORM" \
        "$(show_ver "${CODEX_SOURCE_NEW:-$CODEX_SOURCE_PIN}")" "$CODEX_SOURCE_STATUS"
    printf '| OpenCode (`opencode-ai`) | %s | %s | %s | `%s` |\n' \
        "$(show_ver "$OPENCODE_UP")" "$(show_ver "$OPENCODE_LOONG")" \
        "$(show_ver "$OPENCODE_SEL")" "$OPENCODE_STATUS"
    printf '| DSH (`@deepseek-ai/dsh`) | %s | %s | %s | `%s` |\n' \
        "$(show_ver "$DSH_UP")" "$(show_ver "$DSH_LOONG")" \
        "$(show_ver "$DSH_SEL")" "$DSH_STATUS"
    printf '| Claude Code | %s | %s (cli.js) | %s | `%s` |\n' \
        "$(show_ver "$CLAUDE_UP")" "$(show_ver "$CLAUDE_JS")" \
        "$(show_ver "$CLAUDE_SEL")" "$CLAUDE_STATUS"
    printf '| ZCode (tags) | %s (release) | %s | %s | `%s` |\n' \
        "$(show_ver "$ZCODE_RELEASE")" "$(show_ver "$ZCODE_TAGS")" \
        "$(show_ver "$ZCODE_SEL")" "$ZCODE_STATUS"
    printf '| cc-switch | %s | %s | %s | `%s` |\n' \
        "$(show_ver "$CCSWITCH_RELEASE")" "$(show_ver "$CCSWITCH_RELEASE")" \
        "$(show_ver "$CCSWITCH_SEL")" "$CCSWITCH_STATUS"
} > "$OUT_TABLE"

# --------------------------------------------------------------------------
# apply alignment when selected > pin
# --------------------------------------------------------------------------

CHANGED=0
: > "$TMP/changes.tsv"

consider() {
    local key=$1 name=$2 pin=$3 sel=$4 reason=$5
    [ -n "$sel" ] || return 0
    if version_gt "$sel" "$pin"; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$name" "$pin" "$sel" "$reason" \
            >> "$TMP/changes.tsv"
        CHANGED=1
    fi
}

consider CODEX_VERSION '@openai/codex' "$CODEX_PIN" "$CODEX_LOONG" "$CODEX_NOTE"
consider OPENCODE_VERSION 'opencode-ai' "$OPENCODE_PIN" "$OPENCODE_SEL" 'opencode-linux-loong64 latest'
consider DSH_VERSION '@deepseek-ai/dsh' "$DSH_PIN" "$DSH_SEL" 'Loongnix registry latest'
consider CLAUDE_CODE_VERSION '@anthropic-ai/claude-code' "$CLAUDE_PIN" "$CLAUDE_SEL" 'newest tarball containing cli.js'
consider ZCODE_TAG 'ZCode' "$ZCODE_PIN" "$ZCODE_SEL" 'newest semver tag'
consider CC_SWITCH_VERSION 'cc-switch' "$CCSWITCH_PIN" "$CCSWITCH_SEL" 'latest GitHub release'

set_manifest_value() {
    local key=$1 value=$2 escaped
    escaped=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')
    sed -i.bak "s|^[[:space:]]*${key}=.*|${key}=${escaped}|" "$MANIFEST"
    rm -f "$MANIFEST.bak"
}

set_fallback_value() {
    local key=$1 value=$2 escaped
    escaped=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')
    sed -i.bak "s|^${key}_DEFAULT=.*|${key}_DEFAULT=${escaped}|" "$INSTALLER"
    rm -f "$INSTALLER.bak"
}

# Codex source build: update the recorded version/URL/SHA when the private
# builds release moves, even while the npm channel remains the default.
SOURCE_CHANGED=0
if [ -n "$CODEX_SOURCE_NEW" ]; then
    if version_gt "$CODEX_SOURCE_NEW" "$CODEX_SOURCE_PIN"; then
        SOURCE_CHANGED=1
        SOURCE_OLD=$CODEX_SOURCE_PIN
        SOURCE_NEW=$CODEX_SOURCE_NEW
        SOURCE_REASON="builds release ${CODEX_SOURCE_NEW_NAME:-$CODEX_SOURCE_NEW}"
    elif [ "$CODEX_SOURCE_NEW" = "$CODEX_SOURCE_PIN" ]; then
        if [ "$CODEX_SOURCE_NEW_URL" != "$CODEX_SOURCE_URL_PIN" ] \
            || [ "$CODEX_SOURCE_NEW_SHA" != "$CODEX_SOURCE_SHA_PIN" ]; then
            SOURCE_CHANGED=1
            SOURCE_OLD='stale URL/SHA'
            SOURCE_NEW='refreshed'
            SOURCE_REASON="builds release ${CODEX_SOURCE_NEW_NAME:-$CODEX_SOURCE_NEW}"
        fi
    fi
fi

if [ "$SOURCE_CHANGED" -eq 1 ]; then
    CHANGED=1
    set_manifest_value CODEX_SOURCE_VERSION "$CODEX_SOURCE_NEW"
    set_manifest_value CODEX_SOURCE_URL "$CODEX_SOURCE_NEW_URL"
    set_manifest_value CODEX_SOURCE_SHA256 "$CODEX_SOURCE_NEW_SHA"
    set_fallback_value CODEX_SOURCE_VERSION "$CODEX_SOURCE_NEW"
    set_fallback_value CODEX_SOURCE_URL "$CODEX_SOURCE_NEW_URL"
    set_fallback_value CODEX_SOURCE_SHA256 "$CODEX_SOURCE_NEW_SHA"
    printf 'CODEX_SOURCE\tCodex source\t%s\t%s\t%s\n' \
        "$SOURCE_OLD" "$SOURCE_NEW" "$SOURCE_REASON" >> "$TMP/changes.tsv"
fi

# README block, rendered from the manifest (after updates).
render_readme_block() {
    printf '<!-- agent-versions:begin -->\n'
    printf '| 工具 | selected | 说明 |\n'
    printf '| --- | --- | --- |\n'
    printf '| Node.js | `%s` | ABI2.0 运行时，来自 `loong64/node` |\n' "$(manifest_value NODE_VERSION)"
    printf '| Codex | `%s` | 龙芯 loong64 可用最新版（非上游 latest） |\n' "$(manifest_value CODEX_VERSION)"
    printf '| Codex (source) | `%s` | 私有 builds 仓库的 LoongArch 源码构建（可选通道） |\n' "$(manifest_value CODEX_SOURCE_VERSION)"
    printf '| OpenCode | `%s` | `opencode-linux-loong64` 最新版 |\n' "$(manifest_value OPENCODE_VERSION)"
    printf '| DSH | `%s` | Loongnix registry 最新版 |\n' "$(manifest_value DSH_VERSION)"
    printf '| Claude Code | `%s` | 最后一个 npm tarball 仍带 `cli.js` 的版本 |\n' "$(manifest_value CLAUDE_CODE_VERSION)"
    printf '| ZCode | `%s` | `zai-org/ZCode` 最新 semver tag（非 GitHub release） |\n' "$(manifest_value ZCODE_TAG)"
    printf '| cc-switch | `%s` | `farion1231/cc-switch` 最新 release |\n' "$(manifest_value CC_SWITCH_VERSION)"
    printf '<!-- agent-versions:end -->\n'
}

replace_readme_block() {
    render_readme_block > "$TMP/readme-block.md"
    awk -v newfile="$TMP/readme-block.md" '
        /<!-- agent-versions:begin -->/ {
            while ((getline line < newfile) > 0) print line
            close(newfile)
            skip = 1
            next
        }
        /<!-- agent-versions:end -->/ { skip = 0; next }
        !skip { print }
    ' "$README" > "$TMP/README.new"
    mv "$TMP/README.new" "$README"
}

if [ "$CHANGED" -eq 1 ]; then
    while IFS=$'\t' read -r key name old new reason; do
        [ -n "$key" ] || continue
        case "$key" in
            CODEX_SOURCE) continue ;;
        esac
        set_manifest_value "$key" "$new"
        set_fallback_value "$key" "$new"
    done < "$TMP/changes.tsv"
    if version_gt "$ZCODE_SEL" "$ZCODE_PIN"; then
        set_manifest_value ZCODE_VERSION "$ZCODE_SEL"
    fi
    replace_readme_block
else
    rm -f "$OUT_CHANGES"
fi

# --------------------------------------------------------------------------
# changes.md (PR body)
# --------------------------------------------------------------------------

if [ "$CHANGED" -eq 1 ]; then
    {
        printf '## Agent version alignment\n\n'
        printf 'Automated by `.github/workflows/agent-version-watch.yml`. '
        printf 'Selected versions are the newest **usable on LoongArch**, '
        printf 'not necessarily upstream `latest`.\n\n'
        printf '| 工具 | 旧值 | 新值 | 依据 |\n'
        printf '| --- | --- | --- | --- |\n'
        while IFS=$'\t' read -r key name old new reason; do
            [ -n "$key" ] || continue
            printf '| %s (`%s`) | `%s` | `%s` | %s |\n' "$name" "$key" "$old" "$new" "$reason"
        done < "$TMP/changes.tsv"
        printf '\n`install/versions.env`、installer fallback 块和 README 版本表已同步，'
        printf '并已通过 `check-versions-consistency.sh`、`shellcheck` 和 '
        printf '`ccswitch-lite` 的 `go test` + loong64 构建。\n\n'
        printf '> 如果本 PR 显示 `action required` 且没有任何 job，这是 GitHub 对 '
        printf 'bot 创建 PR 的审批门禁，不是内容失败；维护者 Approve 后 CI 才会运行。'
        printf '分支在推送前已通过上述本地校验。\n\n'
        printf '本 PR 由 workflow 自动创建；不会自动合并、安装或发布。\n'
    } > "$OUT_CHANGES"
fi

# --------------------------------------------------------------------------
# issue body
# --------------------------------------------------------------------------

RUN_URL=''
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

{
    printf '<!-- agent-version-watch -->\n'
    printf '@yunix-intel 龙芯 agent 版本检查（%s UTC）。\n\n' "$TODAY"
    printf '`selected` = 当前 LoongArch 上可用的最新版，不一定是上游 latest。\n\n'
    cat "$OUT_TABLE"
    printf '\n'

    if [ "$CHANGED" -eq 1 ]; then
        printf '### 自动对齐\n\n'
        printf '有 %s 项可升级，workflow 已更新 `install/versions.env`、installer fallback 和 README 表，并推送到 `auto/version-alignment` 分支创建/更新 PR。\n\n' \
            "$(wc -l < "$TMP/changes.tsv" | tr -d ' ')"
        printf '| 工具 | 旧值 | 新值 |\n| --- | --- | --- |\n'
        while IFS=$'\t' read -r key name old new reason; do
            [ -n "$key" ] || continue
            printf '| %s | `%s` | `%s` |\n' "$name" "$old" "$new"
        done < "$TMP/changes.tsv"
        printf '\n'
    else
        printf '### 自动对齐\n\n没有可升级项：清单已与龙芯可用版本一致，本次不创建 PR。\n\n'
    fi

    notes=''
    case "$CODEX_STATUS" in
        waiting-for-loong64-port)
            notes="${notes}- Codex：上游 ${CODEX_UP}，loong64 port 最新 ${CODEX_LOONG}，等待移植。"$'\n' ;;
    esac
    case "$OPENCODE_STATUS" in
        waiting-for-loong64-port)
            notes="${notes}- OpenCode：上游 ${OPENCODE_UP}，\`opencode-linux-loong64\` 最新 ${OPENCODE_LOONG}，等待移植。"$'\n' ;;
    esac
    case "$DSH_STATUS" in
        waiting-upstream-sync)
            notes="${notes}- DSH：上游 ${DSH_UP}，Loongnix 最新 ${DSH_LOONG}，等待同步。"$'\n' ;;
    esac
    if [ "$SOURCE_CHANGED" -eq 1 ]; then
        notes="${notes}- Codex source：builds 仓库 ${CODEX_SOURCE_NEW} 已同步到清单（npm channel 仍为 ${CODEX_CHANNEL_PIN}）。"$'\n'
    fi
    if [ "$CODEX_SOURCE_STATUS" = source-private ]; then
        notes="${notes}- Codex：source build available (private; set AUTO_ALIGN_TOKEN or URL)。清单记录 ${CODEX_SOURCE_PIN}，未改动 npm pin。"$'\n'
    fi
    if [ "$CODEX_SOURCE_STATUS" = source-unavailable ]; then
        notes="${notes}- Codex：已配置 token 但读不到私有 builds release；source 版本保持 ${CODEX_SOURCE_PIN}。"$'\n'
    fi
    if [ "$CODEX_CHANNEL_PIN" = source ] && [ -z "$CODEX_SOURCE_URL_PIN" ] \
        && [ -z "$CODEX_SOURCE_NEW_URL" ]; then
        notes="${notes}- Codex：CODEX_CHANNEL=source 但 CODEX_SOURCE_URL 为空，安装会失败；请提供 URL 或 token。"$'\n'
    fi
    if [ "$CLAUDE_STATUS" = native-only ]; then
        notes="${notes}- Claude Code：上游 ${CLAUDE_UP} 已是 native-only（无 \`cli.js\`，在龙芯上只能 box64 运行）；selected 保持最后一个 JS 版 ${CLAUDE_JS}，不自动升级。"$'\n'
    fi
    if [ "$ZCODE_STATUS" = tag-ahead-of-release ]; then
        notes="${notes}- ZCode：最新 tag 是 ${ZCODE_TAGS}，GitHub release 仍是 ${ZCODE_RELEASE}；按 tag 取 ${ZCODE_TAGS}。"$'\n'
    fi
    if [ "$CODEX_STATUS" = query-failed ] || [ "$OPENCODE_STATUS" = query-failed ] \
        || [ "$DSH_STATUS" = query-failed ] || [ "$CLAUDE_STATUS" = query-failed ] \
        || [ "$ZCODE_STATUS" = query-failed ] || [ "$CCSWITCH_STATUS" = query-failed ]; then
        notes="${notes}- 有 registry/GitHub 查询失败（状态 \`query-failed\`），请查看 workflow 日志；失败项不会被自动降级。"$'\n'
    fi
    if [ -n "$notes" ]; then
        printf '### 说明\n\n%s\n' "$notes"
    fi

    printf '本 issue 由 `.github/workflows/agent-version-watch.yml` 自动创建/更新。'
    printf 'workflow 只检测和对齐版本，不会直接提交 `main`、不会合并 PR、不会安装或发布。\n'
    if [ -n "$RUN_URL" ]; then
        printf '\n运行记录：%s\n' "$RUN_URL"
    fi
} > "$OUT_BODY"

cat "$OUT_TABLE"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    waiting_port=false
    if [ "$CODEX_STATUS" = waiting-for-loong64-port ] \
        || [ "$OPENCODE_STATUS" = waiting-for-loong64-port ]; then
        waiting_port=true
    fi
    {
        printf 'has_changes=%s\n' "$([ "$CHANGED" -eq 1 ] && echo true || echo false)"
        printf 'needs_issue=true\n'
        printf 'waiting_port=%s\n' "$waiting_port"
    } >> "$GITHUB_OUTPUT"
fi
