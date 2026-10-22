#!/bin/sh
# install-zcode-loongarch.sh
#
# Install the loong64 ZCode CLI distribution and/or Tauri desktop deb from a
# private release.  This script is separate from install-loongarch-agents.sh
# because ZCode has a Node 24 runtime dependency and a Web-first UI on loong64.
#
# Usage:
#   sudo ZCODE_CHANNEL=cli \
#     ZCODE_CLI_URL=<asset API URL or https URL> \
#     ZCODE_CLI_SHA256=<64 hex> \
#     ./install-zcode-loongarch.sh
#
#   sudo ZCODE_CHANNEL=desktop \
#     ZCODE_DESKTOP_DEB_URL=... ZCODE_DESKTOP_DEB_SHA256=... \
#     ./install-zcode-loongarch.sh
#
# Environment:
#   ZCODE_CHANNEL=cli|desktop|standalone   (default: cli)
#   ZCODE_VERSION=v3.15.1                  (default: versions.env)
#   ZCODE_CLI_URL / ZCODE_CLI_SHA256
#   ZCODE_DESKTOP_DEB_URL / ZCODE_DESKTOP_DEB_SHA256
#   ZCODE_STANDALONE_DEB_URL / ZCODE_STANDALONE_DEB_SHA256
#   ZCODE_SOURCE_TOKEN                     (private GitHub release asset)
#   ZCODE_NODE=/opt/node24/bin/node        (default: /opt/node24 or PATH)
#   ZCODE_LINK_DEFAULT=1                   (also create /usr/local/bin/zcode)
#   ZCODE_PREFIX=/opt                     (CLI installs to <prefix>/zcode-<ver>)
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
VERSIONS_FILE=${VERSIONS_FILE:-$SCRIPT_DIR/versions.env}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

manifest_get() {
    key=$1
    fallback=$2
    value=''
    if [ -f "$VERSIONS_FILE" ]; then
        value=$(sed -n "s/^[[:space:]]*${key}=//p" "$VERSIONS_FILE" | head -n 1 | tr -d '\r')
    else
        warn "version manifest not found: $VERSIONS_FILE"
    fi
    printf '%s' "${value:-$fallback}"
}

[ "$(id -u)" -eq 0 ] || die "run as root: sudo -E $0"
case "$(uname -m)" in
    loongarch64|loong64) ;;
    *) die "this script targets LoongArch, got: $(uname -m)" ;;
esac

ZCODE_VERSION=${ZCODE_VERSION:-$(manifest_get ZCODE_VERSION "${ZCODE_TAG:-v3.15.1}")}
ZCODE_CHANNEL=${ZCODE_CHANNEL:-$(manifest_get ZCODE_CHANNEL cli)}
ZCODE_CLI_URL=${ZCODE_CLI_URL:-$(manifest_get ZCODE_CLI_URL '')}
ZCODE_CLI_SHA256=${ZCODE_CLI_SHA256:-$(manifest_get ZCODE_CLI_SHA256 '')}
ZCODE_DESKTOP_DEB_URL=${ZCODE_DESKTOP_DEB_URL:-$(manifest_get ZCODE_DESKTOP_DEB_URL '')}
ZCODE_DESKTOP_DEB_SHA256=${ZCODE_DESKTOP_DEB_SHA256:-$(manifest_get ZCODE_DESKTOP_DEB_SHA256 '')}
ZCODE_STANDALONE_DEB_URL=${ZCODE_STANDALONE_DEB_URL:-$(manifest_get ZCODE_STANDALONE_DEB_URL '')}
ZCODE_STANDALONE_DEB_SHA256=${ZCODE_STANDALONE_DEB_SHA256:-$(manifest_get ZCODE_STANDALONE_DEB_SHA256 '')}
ZCODE_SOURCE_TOKEN=${ZCODE_SOURCE_TOKEN:-${GITHUB_TOKEN:-}}
ZCODE_NODE=${ZCODE_NODE:-}
ZCODE_LINK_DEFAULT=${ZCODE_LINK_DEFAULT:-$(manifest_get ZCODE_LINK_DEFAULT 0)}
ZCODE_PREFIX=${ZCODE_PREFIX:-/opt}
BIN_DIR=${BIN_DIR:-/usr/local/bin}

case "$ZCODE_CHANNEL" in
    cli|desktop|standalone) ;;
    *) die "ZCODE_CHANNEL must be cli, desktop or standalone, got: $ZCODE_CHANNEL" ;;
esac
case "$ZCODE_LINK_DEFAULT" in
    0|1) ;;
    *) die "ZCODE_LINK_DEFAULT must be 0 or 1" ;;
esac
case "$ZCODE_PREFIX" in
    /*) ;;
    *) die "ZCODE_PREFIX must be an absolute path" ;;
esac

need curl
need tar
need xz
need sha256sum

TMP=$(mktemp -d "${TMPDIR:-/tmp}/zcode-install.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

download() {
    url=$1
    dest=$2
    [ -n "$url" ] || die "empty download URL"
    case "$url" in
        https://api.github.com/*|https://github.com/*)
            token=$ZCODE_SOURCE_TOKEN ;;
        *) token='' ;;
    esac
    if [ -n "$token" ]; then
        case "$token" in
            *[!A-Za-z0-9_.~+/=-]*) die "ZCODE_SOURCE_TOKEN contains unsupported characters" ;;
        esac
        printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/octet-stream"\n' "$token" \
            | curl --config - -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" \
            || die "download failed: $url"
    else
        curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" \
            || die "download failed: $url"
    fi
}

verify_sha() {
    file=$1
    expected=$2
    [ -n "$expected" ] || die "missing SHA-256 for $(basename "$file")"
    case "$expected" in
        *[!0-9a-fA-F]*) die "SHA-256 must be hex" ;;
    esac
    [ "${#expected}" -eq 64 ] || die "SHA-256 must be 64 hex characters"
    actual=$(sha256sum "$file" | awk '{print $1}')
    [ "$actual" = "$expected" ] || die "SHA-256 mismatch for $(basename "$file"): $actual"
}

choose_node() {
    if [ -n "$ZCODE_NODE" ]; then
        printf '%s' "$ZCODE_NODE"
    elif [ -x /opt/node24/bin/node ]; then
        printf '%s' /opt/node24/bin/node
    else
        command -v node 2>/dev/null || true
    fi
}

install_cli() {
    [ -n "$ZCODE_CLI_URL" ] || die "ZCODE_CHANNEL=cli requires ZCODE_CLI_URL"
    archive="$TMP/zcode-cli.tar.gz"
    log "downloading ZCode CLI $ZCODE_VERSION"
    download "$ZCODE_CLI_URL" "$archive"
    verify_sha "$archive" "$ZCODE_CLI_SHA256"

    tar -tzf "$archive" > "$TMP/list.txt"
    while IFS= read -r p; do
        case "$p" in
            /*|../*|*/../*) die "archive contains unsafe path: $p" ;;
        esac
    done < "$TMP/list.txt"

    mkdir -p "$TMP/extract"
    tar -xzf "$archive" -C "$TMP/extract"
    cli_root=$(find "$TMP/extract" -type d -path '*/dist/zcode' | head -n 1)
    [ -n "$cli_root" ] || die "archive does not contain dist/zcode"
    [ -f "$cli_root/bin/zcode.mjs" ] || die "archive is missing bin/zcode.mjs"

    dest="$ZCODE_PREFIX/zcode-${ZCODE_VERSION#v}"
    if [ -e "$dest" ]; then
        backup="$dest.bak.$(date +%Y%m%d-%H%M%S)"
        log "moving existing $dest to $backup"
        mv "$dest" "$backup"
    fi
    mkdir -p "$ZCODE_PREFIX"
    cp -a "$cli_root" "$dest"
    chmod 0755 "$dest/bin/zcode.mjs"

    node_bin=$(choose_node)
    [ -n "$node_bin" ] && [ -x "$node_bin" ] || die "Node.js >= 24 not found (set ZCODE_NODE)"
    major=$("$node_bin" -p 'process.versions.node.split(".")[0]')
    [ "${major:-0}" -ge 24 ] || die "ZCode needs Node.js >= 24, found $("$node_bin" -v 2>/dev/null || echo unknown)"

    wrapper="$BIN_DIR/zcode-${ZCODE_VERSION#v}"
    cat > "$wrapper" <<EOF
#!/bin/sh
exec "$node_bin" "$dest/bin/zcode.mjs" "\$@"
EOF
    chmod 0755 "$wrapper"
    log "installed $wrapper -> $dest (Node $("$node_bin" -v))"
    if [ "$ZCODE_LINK_DEFAULT" = "1" ]; then
        ln -sf "$wrapper" "$BIN_DIR/zcode"
        log "linked $BIN_DIR/zcode -> $wrapper"
    else
        log "default zcode wrapper left untouched (ZCODE_LINK_DEFAULT=0)"
    fi
}

install_deb() {
    kind=$1
    url=$2
    sha=$3
    [ -n "$url" ] || die "ZCODE_CHANNEL=$kind requires a deb URL"
    deb="$TMP/zcode-$kind.deb"
    log "downloading ZCode $kind deb $ZCODE_VERSION"
    download "$url" "$deb"
    verify_sha "$deb" "$sha"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y "$deb" || die "apt-get install failed for $kind deb"
    else
        dpkg -i "$deb" || die "dpkg -i failed for $kind deb"
    fi
}

case "$ZCODE_CHANNEL" in
    cli) install_cli ;;
    desktop) install_deb desktop "$ZCODE_DESKTOP_DEB_URL" "$ZCODE_DESKTOP_DEB_SHA256" ;;
    standalone) install_deb standalone "$ZCODE_STANDALONE_DEB_URL" "$ZCODE_STANDALONE_DEB_SHA256" ;;
esac

log "done (ZCode $ZCODE_VERSION, channel $ZCODE_CHANNEL)"
