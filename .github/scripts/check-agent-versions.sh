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
CCSWITCH_BUILDS_REPO=${CCSWITCH_BUILDS_REPO:-yunix-intel/cc-switch-loongarch}
MIRROR_REPO=${MIRROR_REPO:-yunix-intel/loongarch-agent-toolkit}
MIRROR_TAG=${MIRROR_TAG:-agent-binaries}
MIRROR_BASE=${MIRROR_BASE:-https://github.com/$MIRROR_REPO/releases/download/$MIRROR_TAG}
DRY_RUN=${DRY_RUN:-false}
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

# Print versions.<version>.dist.integrity, or an empty line if absent.
dist_integrity() {
    local file=$1 version=$2
    [ -s "$file" ] && [ -n "$version" ] || return 0
    "$PYTHON" -I - "$file" "$version" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    dist = (data.get("versions", {}).get(sys.argv[2], {}) or {}).get("dist", {}) or {}
    print(dist.get("integrity", ""))
except Exception:
    print("")
PY
}

# opencode-ai is the package the installer actually installs; the loong64
# platform package is only an optional dependency with a different tarball.
opencode_ai_integrity() {
    local version=$1 file="$TMP/opencode-ai.json"
    [ -n "$version" ] || return 0
    if ! fetch "$LOONG_REGISTRY/opencode-ai" "$file"; then
        warn "failed to query $LOONG_REGISTRY/opencode-ai"
        return 0
    fi
    dist_integrity "$file" "$version"
}

# Claude Code's version endpoint is a single manifest, not a packument.
claude_integrity() {
    local version=$1 file="$TMP/claude-version.json"
    [ -n "$version" ] || return 0
    if ! fetch "$UPSTREAM_REGISTRY/@anthropic-ai%2Fclaude-code/$version" "$file"; then
        warn "failed to query Claude Code $version metadata"
        return 0
    fi
    "$PYTHON" -I - "$file" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
    print((data.get("dist") or {}).get("integrity", ""))
except Exception:
    print("")
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

# Build repositories are private; their downloadable assets are mirrored into
# the public toolkit release.  Never write a private API asset URL into the
# public manifest.
mirror_has_asset() {
    local name=$1
    [ -n "$name" ] || return 1
    gh_api "repos/$MIRROR_REPO/releases/tags/$MIRROR_TAG" \
        --jq '.assets[]?.name' 2>/dev/null | grep -Fxq "$name"
}

mirror_url() {
    printf '%s/%s' "$MIRROR_BASE" "$1"
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

# Release assets of a repository, drafts included, as TSV:
#   tag <TAB> asset name <TAB> asset API URL <TAB> sha256 <TAB> state
# Empty without a token; callers then keep the manifest pin instead of guessing.
private_release_assets() {
    local repo=$1
    # 2 = no token at all; callers report unreadable instead of "up to date".
    [ -n "$BUILDS_TOKEN" ] || return 2
    command -v gh >/dev/null 2>&1 || return 2
    gh_builds_api "repos/$repo/releases?per_page=100" --paginate \
        --jq '.[] | .tag_name as $tag | .assets[]?
              | [$tag, .name, .url, (.digest // ""), (.state // "")] | @tsv' \
        2>/dev/null
}

# Newest cc-switch loong64 deb in the private builds repo.
# Prints: version <TAB> asset API URL <TAB> sha256 <TAB> asset_name
# The version and the deb move as one unit: a release that only bumped the
# upstream tag (no matching deb) is ignored rather than pinned half-way.
ccswitch_build_release() {
    local tsv="$TMP/ccswitch-assets.tsv"
    private_release_assets "$CCSWITCH_BUILDS_REPO" > "$tsv" || return 1
    [ -s "$tsv" ] || return 0
    "$PYTHON" -I - "$tsv" <<'PY'
import re, sys
best = None
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 5:
            continue
        tag, name, url, digest, state = parts
        m = re.match(r"^loongarch-(v[0-9]+\.[0-9]+\.[0-9]+)$", tag)
        if not m or state != "uploaded":
            continue
        if not re.match(r"^cc-switch_[0-9.]+.*_loong64[.]deb$", name):
            continue
        sha = digest[7:] if digest.startswith("sha256:") else digest
        if len(sha) != 64:
            continue
        order = tuple(int(x) for x in m.group(1)[1:].split("."))
        if best is None or order > best[0]:
            best = (order, m.group(1), url, sha, name)
if best:
    print("\t".join(best[1:]))
PY
}

# Newest builds release carrying all three ZCode loong64 assets.
# Prints: version <TAB> cli_url <TAB> cli_sha <TAB> desktop_url <TAB>
#         desktop_sha <TAB> standalone_url <TAB> standalone_sha
# Tags upstream can run ahead of the builds; only a complete, uploaded asset
# set is selectable, so the manifest never points at a missing file.
zcode_build_release() {
    local tsv="$TMP/zcode-assets.tsv"
    private_release_assets "$BUILDS_REPO" > "$tsv" || return 1
    [ -s "$tsv" ] || return 0
    "$PYTHON" -I - "$tsv" <<'PY'
import re, sys
wanted = {
    "cli": re.compile(r"^zcode-cli_[0-9.]+_loong64[.]tar[.]gz$"),
    "desktop": re.compile(r"^zcode-desktop_[0-9.]+_loong64[.]deb$"),
    "standalone": re.compile(r"^zcode-desktop-standalone_[0-9.]+_loong64[.]deb$"),
}
releases = {}
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 5:
            continue
        tag, name, url, digest, state = parts
        m = re.match(r"^zcode-(v[0-9]+\.[0-9]+\.[0-9]+)$", tag)
        if not m or state != "uploaded":
            continue
        sha = digest[7:] if digest.startswith("sha256:") else digest
        if len(sha) != 64:
            continue
        for kind, rx in wanted.items():
            if rx.match(name):
                releases.setdefault(m.group(1), {})[kind] = (url, sha)
best = None
for version, assets in releases.items():
    if set(assets) != set(wanted):
        continue
    order = tuple(int(x) for x in version[1:].split("."))
    if best is None or order > best[0]:
        best = (order, version, assets)
if best:
    _, version, assets = best
    fields = [version]
    for kind in ("cli", "desktop", "standalone"):
        fields.extend(assets[kind])
    print("\t".join(fields))
PY
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
CODEX_SOURCE_NEW_URL=
CODEX_SOURCE_NEW_SHA=$(printf '%s' "$CODEX_SOURCE_TSV" | cut -f3)
CODEX_SOURCE_NEW_NAME=$(printf '%s' "$CODEX_SOURCE_TSV" | cut -f4)
if [ -n "$CODEX_SOURCE_NEW_NAME" ] && mirror_has_asset "$CODEX_SOURCE_NEW_NAME"; then
    CODEX_SOURCE_NEW_URL=$(mirror_url "$CODEX_SOURCE_NEW_NAME")
elif [ -n "$CODEX_SOURCE_NEW" ]; then
    printf 'WARNING: %s is not mirrored in %s; keeping the current public pin\n' \
        "$CODEX_SOURCE_NEW_NAME" "$MIRROR_TAG" >&2
    CODEX_SOURCE_NEW=
fi
OPENCODE_LOONG=$(opencode_loong_latest)
DSH_LOONG=$(dsh_loong_latest)
CLAUDE_JS=$(claude_js_latest)

CODEX_PIN_INTEGRITY=$(manifest_value CODEX_NPM_INTEGRITY)
OPENCODE_PIN_INTEGRITY=$(manifest_value OPENCODE_NPM_INTEGRITY)
DSH_PIN_INTEGRITY=$(manifest_value DSH_NPM_INTEGRITY)
CLAUDE_PIN_INTEGRITY=$(manifest_value CLAUDE_CODE_NPM_INTEGRITY)
CODEX_PIN_REG_INTEGRITY=$(dist_integrity "$TMP/codex-loong.json" "$CODEX_PIN")
OPENCODE_PIN_REG_INTEGRITY=$(opencode_ai_integrity "$OPENCODE_PIN")
DSH_PIN_REG_INTEGRITY=$(dist_integrity "$TMP/dsh-loong.json" "$DSH_PIN")
CLAUDE_PIN_REG_INTEGRITY=$(claude_integrity "$CLAUDE_PIN")
CODEX_INTEGRITY=$(dist_integrity "$TMP/codex-loong.json" "$CODEX_LOONG")
OPENCODE_INTEGRITY=$(opencode_ai_integrity "$OPENCODE_LOONG")
DSH_INTEGRITY=$(dist_integrity "$TMP/dsh-loong.json" "$DSH_LOONG")
CLAUDE_INTEGRITY=$(claude_integrity "$CLAUDE_JS")

# A changed tarball for an already-pinned version is a supply-chain event.
# Refuse to "heal" the pin silently; fail so a human reviews it.
integrity_pin_check() {
    local name=$1 version=$2 pin=$3 registry=$4
    [ -n "$version" ] && [ -n "$pin" ] && [ -n "$registry" ] || return 0
    if [ "$pin" != "$registry" ]; then
        die "integrity mismatch for $name@$version: manifest=$pin registry=$registry"
    fi
}
integrity_pin_check '@openai/codex' "$CODEX_PIN" "$CODEX_PIN_INTEGRITY" "$CODEX_PIN_REG_INTEGRITY"
integrity_pin_check 'opencode-ai' "$OPENCODE_PIN" "$OPENCODE_PIN_INTEGRITY" "$OPENCODE_PIN_REG_INTEGRITY"
integrity_pin_check '@deepseek-ai/dsh' "$DSH_PIN" "$DSH_PIN_INTEGRITY" "$DSH_PIN_REG_INTEGRITY"
integrity_pin_check '@anthropic-ai/claude-code' "$CLAUDE_PIN" "$CLAUDE_PIN_INTEGRITY" "$CLAUDE_PIN_REG_INTEGRITY"

ZCODE_RELEASE=$(gh_latest_release "$ZCODE_REPO")
ZCODE_TAGS=$(gh_tags "$ZCODE_REPO" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
CCSWITCH_RELEASE=$(gh_latest_release "$CCSWITCH_REPO")
ZCODE_READ_FAILED=0
CCSWITCH_READ_FAILED=0
ZCODE_BUILD_TSV=$(zcode_build_release) || ZCODE_READ_FAILED=1
CCSWITCH_BUILD_TSV=$(ccswitch_build_release) || CCSWITCH_READ_FAILED=1

ZCODE_BUILD=$(printf '%s' "$ZCODE_BUILD_TSV" | cut -f1)
ZCODE_BUILD_CLI_URL=$(printf '%s' "$ZCODE_BUILD_TSV" | cut -f2)
ZCODE_BUILD_CLI_SHA=$(printf '%s' "$ZCODE_BUILD_TSV" | cut -f3)
ZCODE_BUILD_DESKTOP_URL=$(printf '%s' "$ZCODE_BUILD_TSV" | cut -f4)
ZCODE_BUILD_DESKTOP_SHA=$(printf '%s' "$ZCODE_BUILD_TSV" | cut -f5)
ZCODE_BUILD_STANDALONE_URL=$(printf '%s' "$ZCODE_BUILD_TSV" | cut -f6)
ZCODE_BUILD_STANDALONE_SHA=$(printf '%s' "$ZCODE_BUILD_TSV" | cut -f7)
if [ -n "$ZCODE_BUILD" ]; then
    ZVER=${ZCODE_BUILD#v}
    ZCODE_CLI_NAME="zcode-cli_${ZVER}_loong64.tar.gz"
    ZCODE_DESKTOP_NAME="zcode-desktop_${ZVER}_loong64.deb"
    ZCODE_STANDALONE_NAME="zcode-desktop-standalone_${ZVER}_loong64.deb"
    if mirror_has_asset "$ZCODE_CLI_NAME" \
        && mirror_has_asset "$ZCODE_DESKTOP_NAME" \
        && mirror_has_asset "$ZCODE_STANDALONE_NAME"; then
        ZCODE_BUILD_CLI_URL=$(mirror_url "$ZCODE_CLI_NAME")
        ZCODE_BUILD_DESKTOP_URL=$(mirror_url "$ZCODE_DESKTOP_NAME")
        ZCODE_BUILD_STANDALONE_URL=$(mirror_url "$ZCODE_STANDALONE_NAME")
    else
        printf 'WARNING: ZCode %s assets are not mirrored in %s; keeping the current public pin\n' \
            "$ZCODE_BUILD" "$MIRROR_TAG" >&2
        ZCODE_BUILD=
    fi
fi

CCSWITCH_BUILD=$(printf '%s' "$CCSWITCH_BUILD_TSV" | cut -f1)
CCSWITCH_BUILD_URL=$(printf '%s' "$CCSWITCH_BUILD_TSV" | cut -f2)
CCSWITCH_BUILD_SHA=$(printf '%s' "$CCSWITCH_BUILD_TSV" | cut -f3)
CCSWITCH_BUILD_NAME=$(printf '%s' "$CCSWITCH_BUILD_TSV" | cut -f4)
if [ -n "$CCSWITCH_BUILD" ] && [ -n "$CCSWITCH_BUILD_NAME" ] \
    && mirror_has_asset "$CCSWITCH_BUILD_NAME"; then
    CCSWITCH_BUILD_URL=$(mirror_url "$CCSWITCH_BUILD_NAME")
elif [ -n "$CCSWITCH_BUILD" ]; then
    printf 'WARNING: cc-switch %s is not mirrored in %s; keeping the current public pin\n' \
        "$CCSWITCH_BUILD_NAME" "$MIRROR_TAG" >&2
    CCSWITCH_BUILD=
fi
ZCODE_CLI_URL_PIN=$(manifest_value ZCODE_CLI_URL)
ZCODE_CLI_SHA_PIN=$(manifest_value ZCODE_CLI_SHA256)
ZCODE_DESKTOP_URL_PIN=$(manifest_value ZCODE_DESKTOP_DEB_URL)
ZCODE_DESKTOP_SHA_PIN=$(manifest_value ZCODE_DESKTOP_DEB_SHA256)
ZCODE_STANDALONE_URL_PIN=$(manifest_value ZCODE_STANDALONE_DEB_URL)
ZCODE_STANDALONE_SHA_PIN=$(manifest_value ZCODE_STANDALONE_DEB_SHA256)
CCSWITCH_URL_PIN=$(manifest_value CC_SWITCH_DEB_URL)
CCSWITCH_SHA_PIN=$(manifest_value CC_SWITCH_DEB_SHA256)

# The npm channel stays the default and keeps tracking the loong64 port; the
# source build is reported separately unless CODEX_CHANNEL=source.
CODEX_SEL=$CODEX_LOONG
if [ "$CODEX_CHANNEL_PIN" = "source" ]; then
    CODEX_SEL=${CODEX_SOURCE_NEW:-$CODEX_SOURCE_PIN}
fi
OPENCODE_SEL=$OPENCODE_LOONG
DSH_SEL=$DSH_LOONG
CLAUDE_SEL=$CLAUDE_JS
ZCODE_SEL=${ZCODE_BUILD:-$ZCODE_PIN}
CCSWITCH_SEL=${CCSWITCH_BUILD:-$CCSWITCH_PIN}

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
CCSWITCH_STATUS=$(status_of "$CCSWITCH_PIN" "$CCSWITCH_SEL" "$CCSWITCH_RELEASE" waiting-for-loongarch-release)

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

# ZCode is selected from the newest complete builds release, while "upstream"
# is the GitHub release / tag.  A tag that has not been built (or whose build
# is not visible without AUTO_ALIGN_TOKEN) never moves the pin.
if [ -z "$ZCODE_BUILD" ]; then
    if [ -z "$ZCODE_TAGS" ] && [ -z "$ZCODE_RELEASE" ]; then
        ZCODE_STATUS='query-failed'
    elif version_gt "$ZCODE_TAGS" "$ZCODE_PIN"; then
        ZCODE_STATUS='waiting-for-loongarch-build'
    else
        ZCODE_STATUS='up-to-date'
    fi
elif version_gt "$ZCODE_BUILD" "$ZCODE_PIN"; then
    ZCODE_STATUS='update-available'
elif version_gt "$ZCODE_TAGS" "$ZCODE_BUILD"; then
    ZCODE_STATUS='waiting-for-loongarch-build'
elif [ -n "$ZCODE_RELEASE" ] && [ "$ZCODE_RELEASE" != "$ZCODE_BUILD" ] \
    && ! version_gt "$ZCODE_RELEASE" "$ZCODE_BUILD"; then
    ZCODE_STATUS='tag-ahead-of-release'
else
    ZCODE_STATUS='up-to-date'
fi

# A token that cannot see the repository is a configuration problem, not a
# missing build; report it instead of silently keeping the pin.
if [ "$CCSWITCH_READ_FAILED" -eq 1 ]; then
    CCSWITCH_STATUS='private-repo-unreadable'
fi
if [ "$ZCODE_READ_FAILED" -eq 1 ]; then
    ZCODE_STATUS='private-repo-unreadable'
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
    printf '| ZCode (tags) | %s (release) | %s (builds) | %s | `%s` |\n' \
        "$(show_ver "$ZCODE_RELEASE")" "$(show_ver "$ZCODE_BUILD")" \
        "$(show_ver "$ZCODE_SEL")" "$ZCODE_STATUS"
    printf '| cc-switch | %s | %s (builds) | %s | `%s` |\n' \
        "$(show_ver "$CCSWITCH_RELEASE")" "$(show_ver "$CCSWITCH_BUILD")" \
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

# npm packages: the selected version and its sha512 integrity move together.
# Without the integrity, an installer update would be rejected later, so do
# not record a version-only change.
consider_pkg() {
    local key=$1 ikey=$2 name=$3 pin=$4 sel=$5 integrity=$6 reason=$7
    [ -n "$sel" ] || return 0
    if version_gt "$sel" "$pin"; then
        if [ -z "$integrity" ]; then
            warn "no registry integrity for $name@$sel; refusing to update $key"
            return 0
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$key" "$name" "$pin" "$sel" "$reason" "$ikey" "$integrity" \
            >> "$TMP/changes.tsv"
        CHANGED=1
    fi
}

consider_pkg CODEX_VERSION CODEX_NPM_INTEGRITY '@openai/codex' "$CODEX_PIN" "$CODEX_LOONG" "$CODEX_INTEGRITY" "$CODEX_NOTE"
consider_pkg OPENCODE_VERSION OPENCODE_NPM_INTEGRITY 'opencode-ai' "$OPENCODE_PIN" "$OPENCODE_SEL" "$OPENCODE_INTEGRITY" 'opencode-linux-loong64 latest'
consider_pkg DSH_VERSION DSH_NPM_INTEGRITY '@deepseek-ai/dsh' "$DSH_PIN" "$DSH_SEL" "$DSH_INTEGRITY" 'Loongnix registry latest'
consider_pkg CLAUDE_CODE_VERSION CLAUDE_CODE_NPM_INTEGRITY '@anthropic-ai/claude-code' "$CLAUDE_PIN" "$CLAUDE_SEL" "$CLAUDE_INTEGRITY" 'newest tarball containing cli.js'

validate_manifest_value() {
    local key=$1 value=$2
    case "$value" in
        *$'\n'*|*$'\r'*) die "manifest value for $key contains a newline" ;;
    esac
    case "$key" in
        *_VERSION|*_TAG)
            printf '%s' "$value" \
                | grep -Eq '^[vV]?[0-9]+(\.[0-9]+)+([._+-][0-9A-Za-z._-]+)?$' \
                || die "invalid $key: $value"
            ;;
        *_SHA256)
            if [ -n "$value" ]; then
                printf '%s' "$value" | grep -Eq '^[0-9a-fA-F]{64}$' \
                    || die "invalid $key: $value"
            fi
            ;;
        *_INTEGRITY)
            if [ -n "$value" ]; then
                printf '%s' "$value" | grep -Eq '^sha512-[A-Za-z0-9+/]+={0,2}$' \
                    || die "invalid $key: $value"
            fi
            ;;
        *_URL)
            if [ -n "$value" ]; then
                case "$value" in
                    https://*) ;;
                    *) die "invalid $key URL: $value" ;;
                esac
                case "$value" in
                    *[[:space:]]*) die "invalid $key URL: whitespace" ;;
                esac
            fi
            ;;
    esac
}

set_manifest_value() {
    local key=$1 value=$2 escaped
    validate_manifest_value "$key" "$value"
    escaped=$(printf '%s' "$value" | sed 's/[&|\\]/\\&/g')
    sed -i.bak "s|^[[:space:]]*${key}=.*|${key}=${escaped}|" "$MANIFEST"
    rm -f "$MANIFEST.bak"
}

set_fallback_value() {
    local key=$1 value=$2 escaped
    validate_manifest_value "$key" "$value"
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

# ZCode: the tag, version and all three asset pins change together.  A tag
# without a complete builds release leaves the manifest untouched.
if [ -n "$ZCODE_BUILD" ]; then
    ZCODE_CHANGED=0
    if version_gt "$ZCODE_BUILD" "$ZCODE_PIN"; then
        ZCODE_CHANGED=1
        ZCODE_OLD=$ZCODE_PIN
        ZCODE_NEW=$ZCODE_BUILD
        ZCODE_REASON="builds release zcode-$ZCODE_BUILD"
    elif [ "$ZCODE_BUILD" = "$ZCODE_PIN" ] \
        && { [ "$ZCODE_BUILD_CLI_URL" != "$ZCODE_CLI_URL_PIN" ] \
            || [ "$ZCODE_BUILD_CLI_SHA" != "$ZCODE_CLI_SHA_PIN" ] \
            || [ "$ZCODE_BUILD_DESKTOP_URL" != "$ZCODE_DESKTOP_URL_PIN" ] \
            || [ "$ZCODE_BUILD_DESKTOP_SHA" != "$ZCODE_DESKTOP_SHA_PIN" ] \
            || [ "$ZCODE_BUILD_STANDALONE_URL" != "$ZCODE_STANDALONE_URL_PIN" ] \
            || [ "$ZCODE_BUILD_STANDALONE_SHA" != "$ZCODE_STANDALONE_SHA_PIN" ]; }; then
        ZCODE_CHANGED=1
        ZCODE_OLD='stale URL/SHA'
        ZCODE_NEW='refreshed'
        ZCODE_REASON="builds release zcode-$ZCODE_BUILD"
    fi
    if [ "$ZCODE_CHANGED" -eq 1 ]; then
        CHANGED=1
        set_manifest_value ZCODE_TAG "$ZCODE_BUILD"
        set_manifest_value ZCODE_VERSION "$ZCODE_BUILD"
        set_manifest_value ZCODE_CLI_URL "$ZCODE_BUILD_CLI_URL"
        set_manifest_value ZCODE_CLI_SHA256 "$ZCODE_BUILD_CLI_SHA"
        set_manifest_value ZCODE_DESKTOP_DEB_URL "$ZCODE_BUILD_DESKTOP_URL"
        set_manifest_value ZCODE_DESKTOP_DEB_SHA256 "$ZCODE_BUILD_DESKTOP_SHA"
        set_manifest_value ZCODE_STANDALONE_DEB_URL "$ZCODE_BUILD_STANDALONE_URL"
        set_manifest_value ZCODE_STANDALONE_DEB_SHA256 "$ZCODE_BUILD_STANDALONE_SHA"
        printf 'ZCODE_ASSETS\tZCode\t%s\t%s\t%s\n' \
            "$ZCODE_OLD" "$ZCODE_NEW" "$ZCODE_REASON" >> "$TMP/changes.tsv"
    fi
fi

# cc-switch: same rule -- the manifest version always names the deb it pins.
if [ -n "$CCSWITCH_BUILD" ]; then
    CCSWITCH_CHANGED=0
    if version_gt "$CCSWITCH_BUILD" "$CCSWITCH_PIN"; then
        CCSWITCH_CHANGED=1
        CCSWITCH_OLD=$CCSWITCH_PIN
        CCSWITCH_NEW=$CCSWITCH_BUILD
        CCSWITCH_REASON="loongarch release ${CCSWITCH_BUILD_NAME:-$CCSWITCH_BUILD}"
    elif [ "$CCSWITCH_BUILD" = "$CCSWITCH_PIN" ] \
        && { [ "$CCSWITCH_BUILD_URL" != "$CCSWITCH_URL_PIN" ] \
            || [ "$CCSWITCH_BUILD_SHA" != "$CCSWITCH_SHA_PIN" ]; }; then
        CCSWITCH_CHANGED=1
        CCSWITCH_OLD='stale URL/SHA'
        CCSWITCH_NEW='refreshed'
        CCSWITCH_REASON="loongarch release ${CCSWITCH_BUILD_NAME:-$CCSWITCH_BUILD}"
    fi
    if [ "$CCSWITCH_CHANGED" -eq 1 ]; then
        CHANGED=1
        set_manifest_value CC_SWITCH_VERSION "$CCSWITCH_BUILD"
        set_manifest_value CC_SWITCH_DEB_URL "$CCSWITCH_BUILD_URL"
        set_manifest_value CC_SWITCH_DEB_SHA256 "$CCSWITCH_BUILD_SHA"
        printf 'CC_SWITCH_PIN\tcc-switch\t%s\t%s\t%s\n' \
            "$CCSWITCH_OLD" "$CCSWITCH_NEW" "$CCSWITCH_REASON" >> "$TMP/changes.tsv"
    fi
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
    printf '| ZCode | `%s` | builds 仓库中资产齐全的最新 release（tag 仅作 upstream） |\n' "$(manifest_value ZCODE_TAG)"
    printf '| cc-switch | `%s` | 私有 builds 仓库中最新的 loong64 deb release |\n' "$(manifest_value CC_SWITCH_VERSION)"
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
    while IFS=$'\t' read -r key name old new reason ikey ival; do
        [ -n "$key" ] || continue
        case "$key" in
            CODEX_SOURCE|ZCODE_ASSETS|CC_SWITCH_PIN) continue ;;
        esac
        set_manifest_value "$key" "$new"
        set_fallback_value "$key" "$new"
        if [ -n "${ikey:-}" ] && [ -n "${ival:-}" ]; then
            set_manifest_value "$ikey" "$ival"
        fi
    done < "$TMP/changes.tsv"
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
        while IFS=$'\t' read -r key name old new reason ikey ival; do
            [ -n "$key" ] || continue
            [ -z "${ikey:-}" ] || reason="$reason（含 integrity）"
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
        if [ "$DRY_RUN" = true ]; then
            printf '有 %s 项可升级；`dry_run=true`，已生成变更但未推送分支、未创建/更新 PR。\n\n' \
                "$(wc -l < "$TMP/changes.tsv" | tr -d ' ')"
        else
            printf '有 %s 项可升级，workflow 已更新 `install/versions.env`、installer fallback 和 README 表，并推送到 `auto/version-alignment` 分支创建/更新 PR。\n\n' \
                "$(wc -l < "$TMP/changes.tsv" | tr -d ' ')"
        fi
        printf '| 工具 | 旧值 | 新值 |\n| --- | --- | --- |\n'
        while IFS=$'\t' read -r key name old new reason ikey ival; do
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
        notes="${notes}- ZCode：最新 tag 是 ${ZCODE_TAGS}，GitHub release 仍是 ${ZCODE_RELEASE}；selected 取已构建的 ${ZCODE_BUILD}。"$'\n'
    fi
    if [ "$ZCODE_STATUS" = waiting-for-loongarch-build ]; then
        notes="${notes}- ZCode：上游 tag 是 ${ZCODE_TAGS}，builds 仓库还没有三件资产齐全的 release；selected 保持 ${ZCODE_PIN}。"$'\n'
    fi
    if [ "$CCSWITCH_STATUS" = waiting-for-loongarch-release ]; then
        notes="${notes}- cc-switch：上游 release 是 ${CCSWITCH_RELEASE}，但没有可读取的 loong64 deb release；selected 保持 ${CCSWITCH_PIN}。"$'\n'
    fi
    if [ "$CCSWITCH_READ_FAILED" -eq 1 ]; then
        notes="${notes}- cc-switch：未配置 AUTO_ALIGN_TOKEN，或 token 无权读取 \`${CCSWITCH_BUILDS_REPO}\`（HTTP 404/403）。请配置 token 并把该仓库加入 Repository access，否则 cc-switch 不会自动对齐；selected 保持 ${CCSWITCH_PIN}。"$'\n'
    fi
    if [ "$ZCODE_READ_FAILED" -eq 1 ]; then
        notes="${notes}- ZCode：未配置 AUTO_ALIGN_TOKEN，或 token 无权读取 \`${BUILDS_REPO}\` 的 release；selected 保持 ${ZCODE_PIN}。"$'\n'
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
