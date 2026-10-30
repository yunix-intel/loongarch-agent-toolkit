#!/usr/bin/env bash
# MODE=check   verify the latest published private assets and print a report;
#              never write the public release.
# MODE=promote verify, prefix per-component signature metadata, upload to the
#              public agent-binaries release, and rebuild SHA256SUMS.
#
# Requires:
#   AUTO_ALIGN_TOKEN: read access to loongarch-agent-builds and cc-switch-loongarch
#   GITHUB_TOKEN:     write access to this public repository (promote only)
#
# The private releases are the staging area.  A maintainer reviews them and
# the check report, then runs the manual promotion workflow.
set -euo pipefail

PRIVATE_TOKEN=${AUTO_ALIGN_TOKEN:?AUTO_ALIGN_TOKEN is required}
MODE=${MODE:-check}
case "$MODE" in
    check|promote) ;;
    *) echo "MODE must be check or promote (got $MODE)" >&2; exit 2 ;;
esac
PUBLIC_TOKEN=''
if [ "$MODE" = promote ]; then
    PUBLIC_TOKEN=${GITHUB_TOKEN:?GITHUB_TOKEN is required for promote}
fi
ALLOW_UNSIGNED=${ALLOW_UNSIGNED:-0}

BUILDS_REPO=yunix-intel/loongarch-agent-builds
CC_REPO=yunix-intel/cc-switch-loongarch
MIRROR_REPO=yunix-intel/loongarch-agent-toolkit
MIRROR_TAG=agent-binaries
MIRROR_BASE="https://github.com/$MIRROR_REPO/releases/download/$MIRROR_TAG"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mirror-agent-assets.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

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

# A missing optional asset is expected on older releases; an asset that is
# listed but cannot be downloaded is a hard failure.
optional_release_asset() {
    local repo=$1 tag=$2 dir=$3 name=$4 assets
    mkdir -p "$dir"
    assets="$TMP/assets.$$.txt"
    if ! GH_TOKEN="$PRIVATE_TOKEN" gh release view "$tag" --repo "$repo" \
        --json assets --jq '.assets[].name' > "$assets"; then
        rm -f "$assets"
        die "cannot list assets of $repo@$tag"
    fi
    if ! grep -Fxq "$name" "$assets"; then
        rm -f "$assets"
        warn "$name is not present in $repo@$tag"
        return 0
    fi
    rm -f "$assets"
    if ! GH_TOKEN="$PRIVATE_TOKEN" gh release download "$tag" \
        --repo "$repo" --pattern "$name" -D "$dir" --clobber; then
        die "failed to download existing asset $name from $repo@$tag"
    fi
}

verify_checksums() {
    local dir=$1 repo=$2 tag=$3 names bad
    [ -f "$dir/SHA256SUMS" ] || die "missing SHA256SUMS in $dir"
    names="$TMP/release-assets.$$.txt"
    if ! GH_TOKEN="$PRIVATE_TOKEN" gh release view "$tag" --repo "$repo" \
        --json assets --jq '.assets[].name' > "$names"; then
        rm -f "$names"
        die "cannot list assets of $repo@$tag"
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
    [ "$bad" -eq 0 ] || die "checksum manifest references missing assets"
    ( cd "$dir" && sha256sum -c --ignore-missing SHA256SUMS )
}

ensure_public_release() {
    local draft
    if GH_TOKEN="$PUBLIC_TOKEN" gh release view "$MIRROR_TAG" \
        --repo "$MIRROR_REPO" >/dev/null 2>&1; then
        draft=$(GH_TOKEN="$PUBLIC_TOKEN" gh release view "$MIRROR_TAG" \
            --repo "$MIRROR_REPO" --json isDraft --jq '.isDraft')
        [ "$draft" = "false" ] || die "$MIRROR_TAG is a draft; publish it before promoting"
    else
        GH_TOKEN="$PUBLIC_TOKEN" gh release create "$MIRROR_TAG" \
            --repo "$MIRROR_REPO" --title "agent-binaries" \
            --notes "Public mirror. Assets are published by the manual promotion workflow."
    fi
}

upload_public() {
    local dir=$1
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f ! -name 'SHA256SUMS*' -print)
    [ "${#files[@]}" -gt 0 ] || die "no assets in $dir"
    GH_TOKEN="$PUBLIC_TOKEN" gh release upload "$MIRROR_TAG" \
        "${files[@]}" --repo "$MIRROR_REPO" --clobber
}

# Stable per-component names prevent the three private releases from
# overwriting each other's signature metadata in the shared release.
prefix_metadata() {
    local dir=$1 prefix=$2 f
    for f in BINARIES-SHA256SUMS BINARIES-SHA256SUMS.sig provenance.json provenance.json.sig; do
        if [ -f "$dir/$f" ]; then
            mv "$dir/$f" "$dir/$prefix-$f"
        fi
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

verify_signatures() {
    local dir=$1 label=$2 key=${3:-$ROOT/release-pubkey.pem}
    if [ -f "$dir/BINARIES-SHA256SUMS.sig" ] || [ -f "$dir/provenance.json.sig" ]; then
        PUBKEY="$key" bash "$ROOT/scripts/verify-release-signature.sh" "$dir"
    else
        warn "no signed manifest for $label (older release)"
    fi
}

CODEX_TAG=$(latest_tag "$BUILDS_REPO" 'codex-rust-v')
ZCODE_TAG=$(latest_tag "$BUILDS_REPO" 'zcode-v')
CC_TAG=$(latest_tag "$CC_REPO" 'loongarch-v')
[ -n "$CODEX_TAG" ] || die "no published Codex build"
[ -n "$ZCODE_TAG" ] || die "no published ZCode build"
[ -n "$CC_TAG" ] || die "no published cc-switch build"

echo "mode:      $MODE"
echo "Codex:     $CODEX_TAG"
echo "ZCode:     $ZCODE_TAG"
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

verify_signatures "$TMP/codex" "$CODEX_TAG"
verify_signatures "$TMP/zcode" "$ZCODE_TAG"
verify_signatures "$TMP/cc-switch" "$CC_TAG" "$ROOT/release-pubkey-ccswitch.pem"

verify_checksums "$TMP/codex" "$BUILDS_REPO" "$CODEX_TAG"
verify_checksums "$TMP/zcode" "$BUILDS_REPO" "$ZCODE_TAG"
verify_checksums "$TMP/cc-switch" "$CC_REPO" "$CC_TAG"

mkdir -p "$TMP/meta"
{
    signature_status "$TMP/codex" codex
    signature_status "$TMP/zcode" zcode
    signature_status "$TMP/cc-switch" cc-switch
} > "$TMP/meta/SIGNATURE-STATUS"

command -v python3 >/dev/null 2>&1 || die "python3 is required to generate SBOM.spdx.json"
python3 -I "$ROOT/scripts/generate-mirror-sbom.py" \
    "$TMP/meta/SBOM.spdx.json" "$MIRROR_BASE" \
    "$TMP/codex" "$TMP/zcode" "$TMP/cc-switch"

unsigned=$(grep -c ' unsigned$' "$TMP/meta/SIGNATURE-STATUS" || true)
if [ "$unsigned" -gt 0 ] && [ "$ALLOW_UNSIGNED" != "1" ]; then
    if [ "$MODE" = promote ]; then
        die "unsigned components present; set ALLOW_UNSIGNED=1 only for a reviewed legacy release"
    fi
    warn "unsigned components present; promote will require ALLOW_UNSIGNED=1"
fi

if [ "$MODE" = check ]; then
    {
        echo "### Private asset check"
        echo
        echo "- Codex: \`$CODEX_TAG\`"
        echo "- ZCode: \`$ZCODE_TAG\`"
        echo "- cc-switch: \`$CC_TAG\`"
        echo
        echo "**Signature status**"
        sed 's/^/- /' "$TMP/meta/SIGNATURE-STATUS"
        echo
        echo "**Component summary:** \`$TMP/meta/SBOM.spdx.json\` ($(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["packages"]))' "$TMP/meta/SBOM.spdx.json") packages)"
        echo
        echo "No public release was modified. Review the private releases, then run **Promote staged binaries**."
    } > "$TMP/report.md"
    cat "$TMP/report.md"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat "$TMP/report.md" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
fi

prefix_metadata "$TMP/codex" codex
prefix_metadata "$TMP/zcode" zcode
prefix_metadata "$TMP/cc-switch" cc-switch

ensure_public_release
upload_public "$TMP/codex"
upload_public "$TMP/zcode"
upload_public "$TMP/cc-switch"
upload_public "$TMP/meta"

GH_TOKEN="$PUBLIC_TOKEN" bash "$ROOT/scripts/refresh-release-checksums.sh" \
    "$MIRROR_REPO" "$MIRROR_TAG"

echo "promoted to $MIRROR_REPO@$MIRROR_TAG"
