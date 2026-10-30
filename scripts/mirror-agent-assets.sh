#!/usr/bin/env bash
# Stage published private build assets into the draft agent-binaries-staging
# release.  Nothing is published to the public agent-binaries release here;
# a maintainer reviews the staging release and runs the manual promotion
# workflow.
#
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
STAGING_TAG=agent-binaries-staging
MIRROR_BASE="https://github.com/$MIRROR_REPO/releases/download/$MIRROR_TAG"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mirror-agent-assets.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

warn() { printf 'warning: %s\n' "$*" >&2; }

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

# Per-artifact SBOMs and signatures are produced by the private build
# workflows.  A missing asset is expected on older releases; an asset that is
# listed but cannot be downloaded is a hard failure.
optional_release_asset() {
    local repo=$1 tag=$2 dir=$3 name=$4 assets
    mkdir -p "$dir"
    assets="$TMP/assets.$$.txt"
    if ! GH_TOKEN="$PRIVATE_TOKEN" gh release view "$tag" --repo "$repo" \
        --json assets --jq '.assets[].name' > "$assets"; then
        rm -f "$assets"
        echo "cannot list assets of $repo@$tag" >&2
        return 1
    fi
    if ! grep -Fxq "$name" "$assets"; then
        rm -f "$assets"
        warn "$name is not present in $repo@$tag"
        return 0
    fi
    rm -f "$assets"
    if ! GH_TOKEN="$PRIVATE_TOKEN" gh release download "$tag" \
        --repo "$repo" --pattern "$name" -D "$dir" --clobber; then
        echo "failed to download existing asset $name from $repo@$tag" >&2
        return 1
    fi
}

verify_checksums() {
    local dir=$1 repo=$2 tag=$3 names bad
    [ -f "$dir/SHA256SUMS" ] || {
        echo "missing SHA256SUMS in $dir" >&2
        return 1
    }
    names="$TMP/release-assets.$$.txt"
    if ! GH_TOKEN="$PRIVATE_TOKEN" gh release view "$tag" --repo "$repo" \
        --json assets --jq '.assets[].name' > "$names"; then
        echo "cannot list assets of $repo@$tag" >&2
        rm -f "$names"
        return 1
    fi
    bad=0
    while read -r _ name; do
        [ -n "$name" ] || continue
        name=${name#\*}
        if [ ! -f "$dir/$name" ] && ! grep -Fxq "$name" "$names"; then
            echo "checksum entry $name is not an asset of $repo@$tag" >&2
            bad=1
        fi
    done < "$dir/SHA256SUMS"
    rm -f "$names"
    [ "$bad" -eq 0 ] || return 1
    ( cd "$dir" && sha256sum -c --ignore-missing SHA256SUMS )
}

ensure_staging_release() {
    local draft
    if GH_TOKEN="$PUBLIC_TOKEN" gh release view "$STAGING_TAG" \
        --repo "$MIRROR_REPO" >/dev/null 2>&1; then
        draft=$(GH_TOKEN="$PUBLIC_TOKEN" gh release view "$STAGING_TAG" \
            --repo "$MIRROR_REPO" --json isDraft --jq '.isDraft')
        [ "$draft" = "true" ] || {
            echo "ERROR: $STAGING_TAG exists but is not a draft" >&2
            exit 1
        }
    else
        GH_TOKEN="$PUBLIC_TOKEN" gh release create "$STAGING_TAG" \
            --repo "$MIRROR_REPO" --draft \
            --title "agent-binaries staging" \
            --notes "Draft staging area. Review assets, SHA256SUMS and signatures, then run Promote staged binaries."
    fi
}

upload_staging() {
    local dir=$1
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f ! -name 'SHA256SUMS*' -print)
    [ "${#files[@]}" -gt 0 ] || {
        echo "no staged assets in $dir" >&2
        return 1
    }
    GH_TOKEN="$PUBLIC_TOKEN" gh release upload "$STAGING_TAG" \
        "${files[@]}" --repo "$MIRROR_REPO" --clobber
}

# Stable per-component names prevent the three private releases from
# overwriting each other's signature metadata in the shared release.
prefix_metadata() {
    local dir=$1 prefix=$2 f
    for f in BINARIES-SHA256SUMS BINARIES-SHA256SUMS.sig provenance.json provenance.json.sig; do
        [ -f "$dir/$f" ] && mv "$dir/$f" "$dir/$prefix-$f"
    done
}

signature_status() {
    local dir=$1 label=$2
    if [ -f "$dir/BINARIES-SHA256SUMS" ] \
        && [ -f "$dir/BINARIES-SHA256SUMS.sig" ] \
        && [ -f "$dir/provenance.json" ] \
        && [ -f "$dir/provenance.json.sig" ]; then
        echo "$label signed"
    else
        echo "$label unsigned"
    fi
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
optional_release_asset "$BUILDS_REPO" "$CODEX_TAG" "$TMP/codex" 'SBOM-codex.spdx.json'
optional_release_asset "$BUILDS_REPO" "$ZCODE_TAG" "$TMP/zcode" 'SBOM-zcode.spdx.json'
optional_release_asset "$CC_REPO" "$CC_TAG" "$TMP/cc-switch" 'SBOM-cc-switch.spdx.json'
for name in BINARIES-SHA256SUMS BINARIES-SHA256SUMS.sig provenance.json provenance.json.sig; do
    optional_release_asset "$BUILDS_REPO" "$CODEX_TAG" "$TMP/codex" "$name"
    optional_release_asset "$BUILDS_REPO" "$ZCODE_TAG" "$TMP/zcode" "$name"
    optional_release_asset "$CC_REPO" "$CC_TAG" "$TMP/cc-switch" "$name"
done

verify_signatures() {
    local dir=$1 label=$2
    if [ -f "$dir/BINARIES-SHA256SUMS.sig" ] || [ -f "$dir/provenance.json.sig" ]; then
        bash "$ROOT/scripts/verify-release-signature.sh" "$dir"
    else
        warn "no signed manifest for $label (older release)"
    fi
}
verify_signatures "$TMP/codex" "$CODEX_TAG"
verify_signatures "$TMP/zcode" "$ZCODE_TAG"
verify_signatures "$TMP/cc-switch" "$CC_TAG"

verify_checksums "$TMP/codex" "$BUILDS_REPO" "$CODEX_TAG"
verify_checksums "$TMP/zcode" "$BUILDS_REPO" "$ZCODE_TAG"
verify_checksums "$TMP/cc-switch" "$CC_REPO" "$CC_TAG"

mkdir -p "$TMP/meta"
{
    signature_status "$TMP/codex" codex
    signature_status "$TMP/zcode" zcode
    signature_status "$TMP/cc-switch" cc-switch
} > "$TMP/meta/SIGNATURE-STATUS"

# The component summary is generated from the exact staged bytes.  The
# per-artifact dependency SBOMs are produced by the private build workflows
# and copied verbatim; this script must not regenerate them from upstream.
command -v python3 >/dev/null 2>&1 || {
    echo "python3 is required to generate SBOM.spdx.json" >&2
    exit 1
}
python3 -I "$ROOT/scripts/generate-mirror-sbom.py" \
    "$TMP/meta/SBOM.spdx.json" "$MIRROR_BASE" \
    "$TMP/codex" "$TMP/zcode" "$TMP/cc-switch"

prefix_metadata "$TMP/codex" codex
prefix_metadata "$TMP/zcode" zcode
prefix_metadata "$TMP/cc-switch" cc-switch

ensure_staging_release
upload_staging "$TMP/codex"
upload_staging "$TMP/zcode"
upload_staging "$TMP/cc-switch"
upload_staging "$TMP/meta"

GH_TOKEN="$PUBLIC_TOKEN" bash "$ROOT/scripts/refresh-release-checksums.sh" \
    "$MIRROR_REPO" "$STAGING_TAG"

echo "staged in $MIRROR_REPO@$STAGING_TAG"
echo "review the draft release, then run the 'Promote staged binaries' workflow"
