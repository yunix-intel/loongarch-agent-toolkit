#!/usr/bin/env bash
# Rebuild a release's SHA256SUMS from the actual asset list.
#
# This intentionally covers every asset (binaries, SBOMs, notices, signatures)
# instead of only the files a workflow happened to download.  It uses the
# SHA256 digest GitHub computes for release assets, so it also works for draft
# staging releases.
#
# Usage: refresh-release-checksums.sh <owner/repo> <tag>
# Requires GH_TOKEN with contents: read/write for that repository.
set -euo pipefail

REPO=${1:?usage: refresh-release-checksums.sh <owner/repo> <tag>}
TAG=${2:?usage: refresh-release-checksums.sh <owner/repo> <tag>}
: "${GH_TOKEN:?GH_TOKEN is required}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/release-checksums.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

gh api "repos/$REPO/releases?per_page=100" --paginate \
    --jq '.[] | select(.tag_name == "'"$TAG"'") | .assets[] | select(.name != "SHA256SUMS") | [.name, (.digest // "")] | @tsv' \
    > "$TMP/assets.tsv"

[ -s "$TMP/assets.tsv" ] || die "release $REPO@$TAG has no assets"

: > "$TMP/SHA256SUMS"
bad=0
while IFS=$'\t' read -r name digest; do
    [ -n "$name" ] || continue
    case "$digest" in
        sha256:*) printf '%s  %s\n' "${digest#sha256:}" "$name" >> "$TMP/SHA256SUMS" ;;
        *) printf 'error: %s has no SHA256 digest\n' "$name" >&2; bad=1 ;;
    esac
done < "$TMP/assets.tsv"
[ "$bad" -eq 0 ] || die "cannot build a complete checksum list"

sort -k2 "$TMP/SHA256SUMS" -o "$TMP/SHA256SUMS"
echo "generated $TMP/SHA256SUMS:"
cat "$TMP/SHA256SUMS"

gh release upload "$TAG" "$TMP/SHA256SUMS" --repo "$REPO" --clobber
echo "uploaded SHA256SUMS to $REPO@$TAG"
