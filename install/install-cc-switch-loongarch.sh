#!/bin/sh
# install-cc-switch-loongarch.sh
#
# Install the official cc-switch Tauri deb from the private LoongArch release.
#
# Usage:
#   sudo CC_SWITCH_SOURCE_TOKEN=<token> ./install-cc-switch-loongarch.sh
#
# The release repository is private; CC_SWITCH_SOURCE_TOKEN (or GITHUB_TOKEN)
# must be able to read its release assets.  Set CC_SWITCH_DEB_URL/SHA256 or rely
# on install/versions.env.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
VERSIONS_FILE=${VERSIONS_FILE:-$SCRIPT_DIR/versions.env}

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

manifest_get() {
    key=$1
    fallback=$2
    value=''
    if [ -f "$VERSIONS_FILE" ]; then
        value=$(sed -n "s/^[[:space:]]*${key}=//p" "$VERSIONS_FILE" | head -n 1 | tr -d '\r')
    fi
    printf '%s' "${value:-$fallback}"
}

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
case "$(uname -m)" in
    loongarch64|loong64) ;;
    *) die "this script targets LoongArch, got: $(uname -m)" ;;
esac

CC_SWITCH_VERSION=${CC_SWITCH_VERSION:-$(manifest_get CC_SWITCH_VERSION v4.0.19)}
CC_SWITCH_DEB_URL=${CC_SWITCH_DEB_URL:-$(manifest_get CC_SWITCH_DEB_URL '')}
CC_SWITCH_DEB_SHA256=${CC_SWITCH_DEB_SHA256:-$(manifest_get CC_SWITCH_DEB_SHA256 '')}
CC_SWITCH_SOURCE_TOKEN=${CC_SWITCH_SOURCE_TOKEN:-}
CC_SWITCH_GITHUB_TOKEN=${GITHUB_TOKEN:-}

case "$CC_SWITCH_VERSION" in
    *[!0-9A-Za-z._-]*) die "invalid CC_SWITCH_VERSION: $CC_SWITCH_VERSION" ;;
esac
[ -n "$CC_SWITCH_DEB_URL" ] || die "CC_SWITCH_DEB_URL is not set"
[ -n "$CC_SWITCH_DEB_SHA256" ] || die "CC_SWITCH_DEB_SHA256 is not set"
case "$CC_SWITCH_DEB_SHA256" in
    *[!0-9a-fA-F]*) die "CC_SWITCH_DEB_SHA256 must be a hex digest" ;;
esac
[ "${#CC_SWITCH_DEB_SHA256}" -eq 64 ] || die "CC_SWITCH_DEB_SHA256 must be 64 hex characters"

need curl
need sha256sum
need dpkg
need dpkg-deb

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cc-switch-install.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM
DEB="$TMP/cc-switch.deb"

log "downloading cc-switch $CC_SWITCH_VERSION"
# Never send an ambient GITHUB_TOKEN to a non-GitHub host.  CC_SWITCH_SOURCE_TOKEN
# is explicit, so it may be used for a mirror the caller chose on purpose.
token=''
case "$CC_SWITCH_DEB_URL" in
    https://api.github.com/*|https://github.com/*)
        token=${CC_SWITCH_SOURCE_TOKEN:-$CC_SWITCH_GITHUB_TOKEN} ;;
    *)
        token=${CC_SWITCH_SOURCE_TOKEN:-} ;;
esac
if [ -n "$token" ]; then
    case "$token" in
        *[!A-Za-z0-9_.~+/=-]*) die "CC_SWITCH_SOURCE_TOKEN contains unsupported characters" ;;
    esac
    printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/octet-stream"\n' "$token" \
        | curl --config - -fL --retry 3 --connect-timeout 20 -o "$DEB" "$CC_SWITCH_DEB_URL" \
        || die "failed to download cc-switch deb"
else
    case "$CC_SWITCH_DEB_URL" in
        https://api.github.com/*)
            curl -fL --retry 3 --connect-timeout 20 \
                -H "Accept: application/octet-stream" -o "$DEB" "$CC_SWITCH_DEB_URL" \
                || die "failed to download cc-switch deb (set CC_SWITCH_SOURCE_TOKEN for the private release)" ;;
        *)
            curl -fL --retry 3 --connect-timeout 20 -o "$DEB" "$CC_SWITCH_DEB_URL" \
                || die "failed to download cc-switch deb" ;;
    esac
fi

actual=$(sha256sum "$DEB" | awk '{print $1}')
[ "$actual" = "$CC_SWITCH_DEB_SHA256" ] || die "cc-switch deb SHA256 mismatch: $actual"

# SHA-256 proves the bytes are the pinned asset; this proves the asset really
# is the version the manifest names (a version bump with a stale URL is a bug).
pkg_version=$(dpkg-deb -f "$DEB" Version)
case "$pkg_version" in
    "${CC_SWITCH_VERSION#v}"|"${CC_SWITCH_VERSION#v}"[.~+-]*) ;;
    *) die "cc-switch deb is version $pkg_version, expected ${CC_SWITCH_VERSION#v}*" ;;
esac

log "installing cc-switch $CC_SWITCH_VERSION"
if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$DEB" || die "apt-get install failed"
else
    dpkg -i "$DEB" || die "dpkg -i failed"
fi

dpkg -s cc-switch >/dev/null 2>&1 || die "cc-switch package was not registered"
log "installed $(dpkg-query -W -f='${Package} ${Version}\n' cc-switch)"
log "launcher: /usr/bin/cc-switch (ccswitch-lite remains /usr/local/bin/ccswitch)"
