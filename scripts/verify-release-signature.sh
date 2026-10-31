#!/usr/bin/env bash
# Verify the signed binary manifest and provenance statement from one release.
# Usage: verify-release-signature.sh <directory> [prefix]
# A prefix selects codex-BINARIES-SHA256SUMS, zcode-provenance.json, etc.
#
# Optional environment:
#   EXPECTED_TAG   provenance.release.tag must match
#   EXPECTED_REPO  provenance.builder.repository must match
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

if [ -f "$DIR/$BINARIES" ]; then
    if [ -z "$PREFIX" ] && [ -f "$DIR/SHA256SUMS" ]; then
        # Private release: the signed manifest must be the exact checksum
        # file used for verification.  A one-way subset would let someone
        # append a new binary to SHA256SUMS without invalidating the signature.
        cmp -s "$DIR/$BINARIES" "$DIR/SHA256SUMS" \
            || die "$BINARIES and SHA256SUMS differ"
    elif [ -f "$DIR/SHA256SUMS" ]; then
        # Public release: SHA256SUMS is a superset (binaries + SBOMs + notices
        # + signatures).  Every signed binary line must still be present.
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
fi

for f in "$BINARIES" "$PROVENANCE"; do
    [ -f "$DIR/$f" ] || die "missing $DIR/$f"
    [ -f "$DIR/$f.sig" ] || die "missing $DIR/$f.sig"
    openssl dgst -sha256 -verify "$PUBKEY" \
        -signature "$DIR/$f.sig" "$DIR/$f" >/dev/null \
        || die "signature verification failed for $f"
    echo "verified $f"
done

if [ -n "${EXPECTED_TAG:-}" ]; then
    grep -Fq "\"tag\": \"$EXPECTED_TAG\"" "$DIR/$PROVENANCE" \
        || die "provenance release tag does not match $EXPECTED_TAG"
fi
if [ -n "${EXPECTED_REPO:-}" ]; then
    grep -Fq "\"repository\": \"$EXPECTED_REPO\"" "$DIR/$PROVENANCE" \
        || die "provenance builder repository does not match $EXPECTED_REPO"
fi
