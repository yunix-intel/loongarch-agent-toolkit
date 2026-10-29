#!/usr/bin/env bash
# Mirror published private build assets into the public agent-binaries release.
# Requires:
#   AUTO_ALIGN_TOKEN: read access to loongarch-agent-builds and cc-switch-loongarch
#   GITHUB_TOKEN:     write access to this public repository
set -euo pipefail

PRIVATE_TOKEN=${AUTO_ALIGN_TOKEN:?AUTO_ALIGN_TOKEN is required}
PUBLIC_TOKEN=${GITHUB_TOKEN:?GITHUB_TOKEN is required}
BUILDS_REPO=yunix-intel/loongarch-agent-builds
CC_REPO=yunix-intel/cc-switch-loongarch
MIRROR_REPO=yunix-intel/loongarch-agent-toolkit
MIRROR_TAG=agent-binaries
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mirror-agent-assets.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

private_api() {
    GH_TOKEN="$PRIVATE_TOKEN" gh api "$@"
}

latest_tag() {
    local repo=$1 prefix=$2
    private_api "repos/$repo/releases?per_page=100" \
        --jq '.[] | select(.draft == false and (.tag_name | startswith("'"$prefix"'"))) | .tag_name' \
        | sort -V | tail -n 1
}

download_release() {
    local repo=$1 tag=$2 dir=$3
    shift 3
    mkdir -p "$dir"
    GH_TOKEN="$PRIVATE_TOKEN" gh release download "$tag" \
        --repo "$repo" "$@" -D "$dir" --clobber
}

verify_checksums() {
    local dir=$1
    [ -f "$dir/SHA256SUMS" ] || {
        echo "missing SHA256SUMS in $dir" >&2
        return 1
    }
    ( cd "$dir" && sha256sum -c SHA256SUMS )
}

upload_public() {
    local dir=$1
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f ! -name 'SHA256SUMS*' -print)
    [ "${#files[@]}" -gt 0 ] || {
        echo "no public assets in $dir" >&2
        return 1
    }
    GH_TOKEN="$PUBLIC_TOKEN" gh release upload "$MIRROR_TAG" \
        "${files[@]}" --repo "$MIRROR_REPO" --clobber
}

update_public_checksums() {
    local dir="$TMP/sums"
    mkdir -p "$dir"
    GH_TOKEN="$PUBLIC_TOKEN" gh release download "$MIRROR_TAG" \
        --repo "$MIRROR_REPO" --pattern SHA256SUMS -D "$dir" --clobber 2>/dev/null || true
    local sums="$dir/SHA256SUMS"
    touch "$sums"
    local d f base sha
    for d in "$TMP/codex" "$TMP/zcode" "$TMP/cc-switch"; do
        while IFS= read -r -d '' f; do
            base=$(basename "$f")
            sha=$(sha256sum "$f" | awk '{print $1}')
            awk -v name="$base" '$2 != name' "$sums" > "$sums.tmp"
            printf '%s  %s\n' "$sha" "$base" >> "$sums.tmp"
            mv "$sums.tmp" "$sums"
        done < <(find "$d" -maxdepth 1 -type f ! -name 'SHA256SUMS*' -print0)
    done
    sort -k2 "$sums" -o "$sums"
    GH_TOKEN="$PUBLIC_TOKEN" gh release upload "$MIRROR_TAG" \
        "$sums" --repo "$MIRROR_REPO" --clobber
}

CODEX_TAG=$(latest_tag "$BUILDS_REPO" 'codex-rust-v')
ZCODE_TAG=$(latest_tag "$BUILDS_REPO" 'zcode-v')
CC_TAG=$(latest_tag "$CC_REPO" 'loongarch-v')
[ -n "$CODEX_TAG" ] || { echo "no published Codex build" >&2; exit 1; }
[ -n "$ZCODE_TAG" ] || { echo "no published ZCode build" >&2; exit 1; }
[ -n "$CC_TAG" ] || { echo "no published cc-switch build" >&2; exit 1; }

echo "Codex:    $CODEX_TAG"
echo "ZCode:    $ZCODE_TAG"
echo "cc-switch: $CC_TAG"

download_release "$BUILDS_REPO" "$CODEX_TAG" "$TMP/codex" \
    --pattern 'codex-rust-*-loongarch64.tar.gz' --pattern 'SHA256SUMS'
download_release "$BUILDS_REPO" "$ZCODE_TAG" "$TMP/zcode" \
    --pattern 'zcode-cli_*_loong64.tar.gz' \
    --pattern 'zcode-desktop_*_loong64.deb' \
    --pattern 'zcode-desktop-standalone_*_loong64.deb' \
    --pattern 'SHA256SUMS'
download_release "$CC_REPO" "$CC_TAG" "$TMP/cc-switch" \
    --pattern 'cc-switch_*.deb' --pattern 'SHA256SUMS'

verify_checksums "$TMP/codex"
verify_checksums "$TMP/zcode"
verify_checksums "$TMP/cc-switch"

upload_public "$TMP/codex"
upload_public "$TMP/zcode"
upload_public "$TMP/cc-switch"
update_public_checksums

echo "mirror complete"
