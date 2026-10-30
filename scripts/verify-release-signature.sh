#!/usr/bin/env bash
# Verify the signed binary manifest and provenance statement from one release.
# Usage: verify-release-signature.sh <directory>
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
DIR=${1:?release asset directory required}
PUBKEY=${PUBKEY:-$ROOT/release-pubkey.pem}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v openssl >/dev/null 2>&1 || die "openssl is required"
[ -f "$PUBKEY" ] || die "public key not found: $PUBKEY"

# The signed binary manifest must be the same file the checksum step uses.
if [ -f "$DIR/SHA256SUMS" ] && ! cmp -s "$DIR/BINARIES-SHA256SUMS" "$DIR/SHA256SUMS"; then
    die "BINARIES-SHA256SUMS and SHA256SUMS differ"
fi

for f in BINARIES-SHA256SUMS provenance.json; do
    [ -f "$DIR/$f" ] || die "missing $DIR/$f"
    [ -f "$DIR/$f.sig" ] || die "missing $DIR/$f.sig"
    openssl dgst -sha256 -verify "$PUBKEY" \
        -signature "$DIR/$f.sig" "$DIR/$f" >/dev/null \
        || die "signature verification failed for $f"
    echo "verified $f"
done
