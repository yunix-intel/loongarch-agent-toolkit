#!/usr/bin/env bash
# Verify the signed binary manifest and provenance statement from one release.
# Usage: verify-release-signature.sh <directory> [prefix]
# A prefix selects codex-BINARIES-SHA256SUMS, zcode-provenance.json, etc.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIR=${1:?release asset directory required}
PREFIX=${2:-}
PUBKEY=${PUBKEY:-$ROOT/release-pubkey.pem}
BINARIES="${PREFIX}BINARIES-SHA256SUMS"
PROVENANCE="${PREFIX}provenance.json"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || die "openssl is required"
[ -f "$PUBKEY" ] || die "public key not found: $PUBKEY"

# The public SHA256SUMS is a superset (binaries + SBOMs + notices + signatures).
# Every line of the signed binary manifest must appear in it unchanged.  The
# comparison ignores the binary marker some sha256sum builds put before names.
if [ -f "$DIR/SHA256SUMS" ] && [ -f "$DIR/$BINARIES" ]; then
    norm=$(mktemp)
    awk '{n=$2; sub(/^\*/, "", n); print tolower($1) "  " n}' "$DIR/SHA256SUMS" \
        | sort > "$norm"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        hash=${1:-}
        name=${2:-}
        [ -n "$hash" ] && [ -n "$name" ] || continue
        name=${name#\*}
        hash=$(printf '%s' "$hash" | tr 'A-F' 'a-f')
        grep -Fqx "$hash  $name" "$norm" || {
            rm -f "$norm"
            die "$BINARIES line is missing from SHA256SUMS: $hash  $name"
        }
    done < "$DIR/$BINARIES"
    rm -f "$norm"
fi

for f in "$BINARIES" "$PROVENANCE"; do
    [ -f "$DIR/$f" ] || die "missing $DIR/$f"
    [ -f "$DIR/$f.sig" ] || die "missing $DIR/$f.sig"
    openssl dgst -sha256 -verify "$PUBKEY" \
        -signature "$DIR/$f.sig" "$DIR/$f" >/dev/null \
        || die "signature verification failed for $f"
    echo "verified $f"
done
