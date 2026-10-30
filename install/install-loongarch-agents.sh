#!/bin/sh
# install-loongarch-agents.sh
#
# Install an ABI2.0 Node.js runtime and the LoongArch builds of:
#   - @openai/codex
#   - opencode-ai
#   - @deepseek-ai/dsh
#
# The system Node is left untouched. Everything is installed under
# /opt/node22-abi2 by default and exposed through /usr/local/bin wrappers.
#
# Background:
#   * LoongArch ELF e_flags 0x3  = ABI1.0 (OBJ-v0)
#   * LoongArch ELF e_flags 0x43 = ABI2.0 (OBJ-v1)
#   * The Node 22.16 tarball on the Loongnix FTP is ABI1.0. dsh's koffi native
#     addon and the ABI2.0 userspace need the 0x43 build. Use loong64/node
#     v22.23.3 (or newer) from GitHub instead.
#   * Node < 22.18 has no import.meta.main; dsh's lib/bin.js then exits
#     silently. This script installs a small shim in that case.
#
# Usage:
#   sudo ./install-loongarch-agents.sh
#
# Versions:
#   install/versions.env is the single source of truth.  The values below are
#   only fallbacks used when that file is missing (e.g. the script is copied
#   standalone); CI keeps them in sync with versions.env.
#
# Overridable environment (environment variables win over versions.env):
#   NODE_VERSION=<from versions.env>
#   NODE_PREFIX=/opt/node22-abi2
#   NPM_REGISTRY=https://registry.loongnix.cn:5873
#   VERSIONS_FILE=<path to versions.env>
#   CODEX_CHANNEL=npm|source
#   CODEX_VERSION=<npm channel version>
#   CODEX_SOURCE_VERSION=<source channel version>
#   CODEX_SOURCE_URL=<http(s) URL or local .tar.gz>
#   CODEX_SOURCE_SHA256=<sha256 of the source archive>
#   CODEX_SOURCE_TOKEN=<token for private GitHub release assets>
#   CODEX_SOURCE_PREFIX=/opt   # source build is unpacked to <prefix>/codex-<ver>
#   CODEX_LINK_DEFAULT=1   # also point /usr/local/bin/codex at the source build
#   OPENCODE_VERSION=<from versions.env>
#   DSH_VERSION=<from versions.env>
#   BIN_DIR=/usr/local/bin
#   NODE_URL=<explicit tarball URL>
#   ALLOW_ABI1=1   # force installation on an ABI1.0 userspace (not recommended)
#
# Source channel:
#   CODEX_CHANNEL=source sudo -E ./install-loongarch-agents.sh
# unpacks CODEX_SOURCE_URL to /opt/codex-<version> and creates
# /usr/local/bin/codex-<version>. The default `codex` wrapper is only replaced
# when CODEX_LINK_DEFAULT=1; otherwise an existing npm `codex` is left as is.

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
VERSIONS_FILE=${VERSIONS_FILE:-$SCRIPT_DIR/versions.env}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

# Read KEY=VALUE from versions.env without executing the file.  $1 is the key
# and $2 the fallback used when the manifest is absent or has no such key.
manifest_get() {
    key=$1
    fallback=$2
    value=''
    if [ -f "$VERSIONS_FILE" ]; then
        value=$(sed -n "s/^[[:space:]]*${key}=//p" "$VERSIONS_FILE" | head -n 1 | tr -d '\r')
    else
        warn "version manifest not found: $VERSIONS_FILE (using built-in fallbacks)"
    fi
    printf '%s' "${value:-$fallback}"
}

# BEGIN VERSION FALLBACKS -- kept in sync with install/versions.env by CI.
NODE_VERSION_DEFAULT=22.23.3
NODE_SHA256_DEFAULT=bbf4ecadfb5dcfe8420998f4539b927edbaea92c2a5f60057317be2fe41ad654
CODEX_CHANNEL_DEFAULT=npm
CODEX_VERSION_DEFAULT=0.164.0
CODEX_SOURCE_VERSION_DEFAULT=0.164.0
CODEX_SOURCE_URL_DEFAULT=https://github.com/yunix-intel/loongarch-agent-toolkit/releases/download/agent-binaries/codex-rust-v0.164.0-loongarch64.tar.gz
CODEX_SOURCE_SHA256_DEFAULT=55b9bbcc9f51ba528e9d7fcbc9e9f085ea7a67c13f95c858c75cee0640a75e09
CODEX_LINK_DEFAULT_DEFAULT=0
OPENCODE_VERSION_DEFAULT=1.19.0
DSH_VERSION_DEFAULT=0.2.1-rc.2
# END VERSION FALLBACKS

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"

ARCH=$(uname -m)
case "$ARCH" in
    loongarch64|loong64) ;;
    *) die "this script targets LoongArch, got: $ARCH" ;;
esac

NODE_VERSION=${NODE_VERSION:-$(manifest_get NODE_VERSION "$NODE_VERSION_DEFAULT")}
NODE_SHA256=${NODE_SHA256:-$(manifest_get NODE_SHA256 "$NODE_SHA256_DEFAULT")}
NODE_PREFIX=${NODE_PREFIX:-/opt/node22-abi2}
NPM_REGISTRY=${NPM_REGISTRY:-https://registry.loongnix.cn:5873}
CODEX_CHANNEL=${CODEX_CHANNEL:-$(manifest_get CODEX_CHANNEL "$CODEX_CHANNEL_DEFAULT")}
CODEX_VERSION=${CODEX_VERSION:-$(manifest_get CODEX_VERSION "$CODEX_VERSION_DEFAULT")}
CODEX_NPM_INTEGRITY=${CODEX_NPM_INTEGRITY:-$(manifest_get CODEX_NPM_INTEGRITY '')}
CODEX_SOURCE_VERSION=${CODEX_SOURCE_VERSION:-$(manifest_get CODEX_SOURCE_VERSION "$CODEX_SOURCE_VERSION_DEFAULT")}
CODEX_SOURCE_URL=${CODEX_SOURCE_URL:-$(manifest_get CODEX_SOURCE_URL "$CODEX_SOURCE_URL_DEFAULT")}
CODEX_SOURCE_SHA256=${CODEX_SOURCE_SHA256:-$(manifest_get CODEX_SOURCE_SHA256 "$CODEX_SOURCE_SHA256_DEFAULT")}
CODEX_SOURCE_TOKEN=${CODEX_SOURCE_TOKEN:-}
CODEX_SOURCE_PREFIX=${CODEX_SOURCE_PREFIX:-/opt}
CODEX_LINK_DEFAULT=${CODEX_LINK_DEFAULT:-$(manifest_get CODEX_LINK_DEFAULT "$CODEX_LINK_DEFAULT_DEFAULT")}
OPENCODE_VERSION=${OPENCODE_VERSION:-$(manifest_get OPENCODE_VERSION "$OPENCODE_VERSION_DEFAULT")}
OPENCODE_NPM_INTEGRITY=${OPENCODE_NPM_INTEGRITY:-$(manifest_get OPENCODE_NPM_INTEGRITY '')}
DSH_VERSION=${DSH_VERSION:-$(manifest_get DSH_VERSION "$DSH_VERSION_DEFAULT")}
DSH_NPM_INTEGRITY=${DSH_NPM_INTEGRITY:-$(manifest_get DSH_NPM_INTEGRITY '')}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
NODE_URL=${NODE_URL:-https://github.com/loong64/node/releases/download/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-loong64.tar.xz}

case "$CODEX_CHANNEL" in
    npm|source) ;;
    *) die "CODEX_CHANNEL must be 'npm' or 'source', got: $CODEX_CHANNEL" ;;
esac
case "$CODEX_LINK_DEFAULT" in
    0|1) ;;
    *) die "CODEX_LINK_DEFAULT must be 0 or 1, got: $CODEX_LINK_DEFAULT" ;;
esac

need readelf
need curl
need tar
need xz
need sha256sum
need install

case "$NODE_PREFIX" in
    /*) ;;
    *) die "NODE_PREFIX must be an absolute path: $NODE_PREFIX" ;;
esac

elf_flags() {
    LC_ALL=C readelf -h "$1" 2>/dev/null \
        | sed -n 's/^ *Flags: *\([^, ]*\).*/\1/p' \
        | head -n 1
}

abi_name() {
    case "$1" in
        0x43|0X43) echo "ABI2.0" ;;
        0x3|0X3)   echo "ABI1.0" ;;
        *)         echo "unknown" ;;
    esac
}

SYS_ABI=unknown
for probe in /bin/ls /usr/bin/env; do
    if [ -x "$probe" ]; then
        SYS_ABI=$(abi_name "$(elf_flags "$probe")")
        break
    fi
done
log "system ABI: $SYS_ABI (probe ${probe:-none})"

if [ "$SYS_ABI" = "ABI1.0" ] && [ "${ALLOW_ABI1:-0}" != "1" ]; then
    die "ABI1.0 userspace detected. ABI2.0 Node cannot run here.
     The Loongnix FTP Node 22.16 tarball is also ABI1.0 (e_flags 0x3).
     Use an ABI2.0 (Loongnix 2025+/newer) system, or set ALLOW_ABI1=1 to force."
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/loongarch-agents.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

NODE_TARBALL=$(basename "$NODE_URL")
log "downloading Node $NODE_VERSION from $NODE_URL"
curl -fL --retry 3 --connect-timeout 20 -o "$TMP/$NODE_TARBALL" "$NODE_URL"

if [ -n "$NODE_SHA256" ]; then
    case "$NODE_SHA256" in
        *[!0-9a-fA-F]*) die "NODE_SHA256 must be a hex digest" ;;
    esac
    [ "${#NODE_SHA256}" -eq 64 ] || die "NODE_SHA256 must be 64 hex characters"
    actual=$(sha256sum "$TMP/$NODE_TARBALL" | awk '{print $1}')
    [ "$actual" = "$NODE_SHA256" ] \
        || die "Node checksum mismatch: expected $NODE_SHA256, got $actual"
elif curl -fsSL --retry 2 -o "$TMP/$NODE_TARBALL.sha256" "$NODE_URL.sha256"; then
    ( cd "$TMP" && sha256sum -c "$NODE_TARBALL.sha256" ) || die "Node checksum mismatch"
else
    if [ "${ALLOW_UNVERIFIED_NODE:-0}" = "1" ]; then
        warn "no pinned NODE_SHA256 and no .sha256 asset; continuing because ALLOW_UNVERIFIED_NODE=1"
    else
        die "no pinned NODE_SHA256 and no .sha256 asset; refusing to install unverified Node (set ALLOW_UNVERIFIED_NODE=1 to override)"
    fi
fi

mkdir -p "$TMP/node"
if tar -tJf "$TMP/$NODE_TARBALL" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    die "Node archive contains an absolute or parent-traversal path"
fi
if tar -tvJf "$TMP/$NODE_TARBALL" | grep -E '^[lh]' \
    | grep -Eq ' (->|link to) /'; then
    die "Node archive contains an absolute symlink target"
fi
tar -xJf "$TMP/$NODE_TARBALL" -C "$TMP/node" --strip-components=1

[ -x "$TMP/node/bin/node" ] || die "Node install failed: $TMP/node/bin/node missing"
NODE_ABI=$(abi_name "$(elf_flags "$TMP/node/bin/node")")
NODE_VER=$("$TMP/node/bin/node" -v)
log "downloaded Node $NODE_VER ($NODE_ABI)"
[ "$NODE_ABI" = "ABI2.0" ] || die "downloaded Node is $NODE_ABI, expected ABI2.0"

if [ -e "$NODE_PREFIX" ]; then
    BACKUP="$NODE_PREFIX.bak.$(date +%Y%m%d-%H%M%S)"
    log "moving existing $NODE_PREFIX to $BACKUP"
    mv "$NODE_PREFIX" "$BACKUP"
fi
mkdir -p "$(dirname "$NODE_PREFIX")"
if ! mv "$TMP/node" "$NODE_PREFIX"; then
    if [ -n "${BACKUP:-}" ]; then
        rm -rf "$NODE_PREFIX"
        mv "$BACKUP" "$NODE_PREFIX"
        die "failed to install Node; restored $BACKUP"
    fi
    die "failed to install Node at $NODE_PREFIX"
fi

[ -x "$NODE_PREFIX/bin/node" ] || die "Node install failed: $NODE_PREFIX/bin/node missing"
NODE_VER=$("$NODE_PREFIX/bin/node" -v)
log "installed Node $NODE_VER at $NODE_PREFIX ($NODE_ABI)"

NPM="$NODE_PREFIX/bin/npm"
[ -x "$NPM" ] || die "npm missing in $NODE_PREFIX"

# npm's shebang is `#!/usr/bin/env node`. Without this PATH change it would
# silently run under the system Node and install into /usr instead of
# NODE_PREFIX (and pick the wrong native artifacts).
PATH="$NODE_PREFIX/bin:$PATH"
export PATH

install_pkg() {
    pkg=$1
    version=$2
    integrity=${3:-}
    ignore_scripts=${4:-0}
    case "$ignore_scripts" in
        0|1) ;;
        *) die "invalid ignore_scripts for $pkg: $ignore_scripts" ;;
    esac
    case "$integrity" in
        ''|sha512-*) ;;
        *) die "invalid npm integrity for $pkg: $integrity" ;;
    esac
    if [ -n "$integrity" ]; then
        need openssl
    fi
    attempt=1
    log "installing $pkg@$version from $NPM_REGISTRY"
    while :; do
        src="$pkg@$version"
        packdir=''
        pack_failed=0
        if [ -n "$integrity" ]; then
            packdir="$TMP/npm-pack.$$.$attempt"
            rm -rf "$packdir"
            mkdir -p "$packdir"
            if "$NPM" pack "$pkg@$version" \
                --registry "$NPM_REGISTRY" \
                --pack-destination "$packdir" >/dev/null; then
                tgz=$(find "$packdir" -maxdepth 1 -type f -name '*.tgz' | head -n 1)
                if [ -z "$tgz" ]; then
                    pack_failed=1
                else
                    actual="sha512-$(openssl dgst -sha512 -binary "$tgz" | openssl base64 -A)"
                    [ "$actual" = "$integrity" ] \
                        || die "npm integrity mismatch for $pkg@$version: expected $integrity, got $actual"
                    src=$tgz
                fi
            else
                pack_failed=1
            fi
        fi
        set -- install -g \
            --prefix "$NODE_PREFIX" \
            --registry "$NPM_REGISTRY" \
            --fetch-retries 3 \
            --no-audit --no-fund
        if [ "$ignore_scripts" = 1 ]; then
            set -- "$@" --ignore-scripts
        fi
        set -- "$@" "$src"
        if [ "$pack_failed" -eq 0 ] && "$NPM" "$@"; then
            [ -z "$packdir" ] || rm -rf "$packdir"
            return 0
        fi
        [ -z "$packdir" ] || rm -rf "$packdir"
        if [ "$attempt" -ge 2 ]; then
            die "npm install $pkg@$version failed twice"
        fi
        attempt=$((attempt + 1))
        warn "npm install $pkg@$version failed; retrying once"
        sleep 2
    done
}

# Download a source archive. For private GitHub release assets the token is
# fed through curl's config on stdin so it never appears in argv or logs.
codex_download() {
    url=$1
    dest=$2
    token=''
    case "$url" in
        https://api.github.com/*|https://github.com/*)
            token=${CODEX_SOURCE_TOKEN:-${GITHUB_TOKEN:-}}
            ;;
        *)
            token=${CODEX_SOURCE_TOKEN:-}
            ;;
    esac
    if [ -n "$token" ]; then
        case "$token" in
            *[!A-Za-z0-9_.~+/=-]*)
                die "CODEX_SOURCE_TOKEN contains unsupported characters" ;;
        esac
        printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/octet-stream"\n' "$token" \
            | curl --config - -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" \
            || die "failed to download Codex source archive"
    else
        case "$url" in
            https://api.github.com/*)
                curl -fL --retry 3 --connect-timeout 20 \
                    -H "Accept: application/octet-stream" -o "$dest" "$url" \
                    || die "failed to download Codex source archive" ;;
            *)
                curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url" \
                    || die "failed to download Codex source archive" ;;
        esac
    fi
}

# Install a Codex source build without touching the npm `codex` wrapper unless
# CODEX_LINK_DEFAULT=1. Sets CODEX_SOURCE_WRAPPER for the caller.
install_codex_source() {
    version=$1
    url=$2
    sha=$3

    [ -n "$version" ] || die "CODEX_CHANNEL=source requires CODEX_SOURCE_VERSION"
    case "$version" in
        *[!0-9A-Za-z._-]*) die "invalid CODEX_SOURCE_VERSION: $version" ;;
    esac
    [ -n "$url" ] || die "CODEX_CHANNEL=source requires CODEX_SOURCE_URL (http(s) URL or local .tar.gz)"
    [ -n "$sha" ] || die "CODEX_CHANNEL=source requires CODEX_SOURCE_SHA256"
    case "$sha" in
        *[!0-9a-fA-F]*) die "CODEX_SOURCE_SHA256 must be a hex digest" ;;
    esac
    [ "${#sha}" -eq 64 ] || die "CODEX_SOURCE_SHA256 must be 64 hex characters"
    sha=$(printf '%s' "$sha" | tr 'A-F' 'a-f')

    archive="$TMP/codex-source.tar.gz"
    case "$url" in
        http://*|https://*)
            log "downloading Codex $version source build"
            codex_download "$url" "$archive"
            ;;
        *)
            [ -f "$url" ] || die "local Codex source archive not found: $url"
            archive=$url
            ;;
    esac

    actual=$(sha256sum "$archive" | awk '{print $1}')
    [ "$actual" = "$sha" ] || die "Codex source checksum mismatch: expected $sha, got $actual"

    # Reject absolute paths and path traversal before unpacking.
    if tar -tzf "$archive" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
        die "Codex source archive contains unsafe paths"
    fi
    if tar -tvzf "$archive" | grep -E '^[lh]' \
        | grep -Eq ' (->|link to) (/|(.*/)?\.\.(/|$))'; then
        die "Codex source archive contains an unsafe link target"
    fi
    # Reject a symlink/hardlink entry for the codex executable before
    # extracting; a later chmod would otherwise follow it.
    if tar -tvzf "$archive" | grep -E '^[lh]' \
        | grep -Eq '(^|/)codex( |$)'; then
        die "Codex source archive contains a symlink entry for codex"
    fi

    src="$TMP/codex-src"
    mkdir -p "$src"
    tar -xzf "$archive" -C "$src"

    bin=''
    for candidate in "$src"/*/bin/codex "$src"/*/codex "$src"/bin/codex "$src"/codex; do
        if [ -f "$candidate" ]; then
            bin=$candidate
            break
        fi
    done
    if [ -z "$bin" ]; then
        bin=$(find "$src" -type f -name codex | head -n 1)
    fi
    [ -n "$bin" ] || die "codex binary not found in the source archive"
    if [ -L "$bin" ]; then
        die "codex source binary is a symlink: $bin"
    fi
    [ -x "$bin" ] || chmod 0755 "$bin"

    rel=${bin#"$src"/}
    dest="$CODEX_SOURCE_PREFIX/codex-$version"
    if [ -e "$dest" ]; then
        backup="$dest.bak.$(date +%Y%m%d-%H%M%S)"
        log "moving existing $dest to $backup"
        mv "$dest" "$backup"
    fi
    mkdir -p "$(dirname "$dest")"
    mv "$src" "$dest"

    installed_bin="$dest/$rel"
    [ -x "$installed_bin" ] || die "installed codex binary is not executable: $installed_bin"

    mkdir -p "$BIN_DIR"
    cat > "$BIN_DIR/codex-$version" <<EOF
#!/bin/sh
# generated by install-loongarch-agents.sh (source channel)
exec "$installed_bin" "\$@"
EOF
    chmod 0755 "$BIN_DIR/codex-$version"

    if [ "$CODEX_LINK_DEFAULT" = "1" ]; then
        cat > "$BIN_DIR/codex" <<EOF
#!/bin/sh
# generated by install-loongarch-agents.sh (source channel)
exec "$installed_bin" "\$@"
EOF
        chmod 0755 "$BIN_DIR/codex"
    fi

    log "installed Codex $version source build at $dest"
}

if [ "$CODEX_CHANNEL" = "npm" ]; then
    # Codex ships prebuilt optional native packages; do not run its scripts.
    install_pkg "@openai/codex" "$CODEX_VERSION" "$CODEX_NPM_INTEGRITY" 1
fi
# OpenCode likewise ships prebuilt optional native packages.
install_pkg "opencode-ai" "$OPENCODE_VERSION" "$OPENCODE_NPM_INTEGRITY" 1
# dsh currently has no linux-loong64 node-pty prebuild, so npm may build it
# with node-gyp.  Keep lifecycle scripts enabled and warn early instead.
for tool in gcc g++ make python3; do
    command -v "$tool" >/dev/null 2>&1 \
        || warn "$tool not found; dsh node-pty may fail to build from source"
done
install_pkg "@deepseek-ai/dsh" "$DSH_VERSION" "$DSH_NPM_INTEGRITY" 0

CODEX_JS="$NODE_PREFIX/lib/node_modules/@openai/codex/bin/codex.js"
DSH_JS="$NODE_PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
OPENCODE_BIN="$NODE_PREFIX/lib/node_modules/opencode-ai/bin/opencode.exe"

if [ "$CODEX_CHANNEL" = "npm" ]; then
    [ -f "$CODEX_JS" ] || die "codex entrypoint not found: $CODEX_JS"
fi
[ -f "$DSH_JS" ] || die "dsh entrypoint not found: $DSH_JS"
[ -x "$OPENCODE_BIN" ] || die "opencode binary not found: $OPENCODE_BIN"

# Node 22.18+ supports import.meta.main; older builds need the shim.
DSH_ENTRY=$DSH_JS
if ! "$NODE_PREFIX/bin/node" --input-type=module \
        -e 'if (!("main" in import.meta)) process.exit(1)' >/dev/null 2>&1; then
    warn "Node $NODE_VER lacks import.meta.main; installing dsh shim"
    install -m 0644 "$SCRIPT_DIR/dsh-node22-shim.mjs" \
        "$NODE_PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/dsh-node22-shim.mjs"
    DSH_ENTRY="$NODE_PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/dsh-node22-shim.mjs"
fi

mkdir -p "$BIN_DIR"

if [ "$CODEX_CHANNEL" = "npm" ]; then
    cat > "$BIN_DIR/codex" <<EOF
#!/bin/sh
# generated by install-loongarch-agents.sh (npm channel)
exec "$NODE_PREFIX/bin/node" "$CODEX_JS" "\$@"
EOF
fi

cat > "$BIN_DIR/dsh" <<EOF
#!/bin/sh
# generated by install-loongarch-agents.sh
exec "$NODE_PREFIX/bin/node" "$DSH_ENTRY" "\$@"
EOF

cat > "$BIN_DIR/opencode" <<EOF
#!/bin/sh
# generated by install-loongarch-agents.sh
exec "$OPENCODE_BIN" "\$@"
EOF

chmod 0755 "$BIN_DIR/dsh" "$BIN_DIR/opencode"
if [ "$CODEX_CHANNEL" = "npm" ]; then
    chmod 0755 "$BIN_DIR/codex"
fi

if [ "$CODEX_CHANNEL" = "source" ]; then
    install_codex_source "$CODEX_SOURCE_VERSION" "$CODEX_SOURCE_URL" "$CODEX_SOURCE_SHA256"
fi

log "verifying wrappers"
if [ "$CODEX_CHANNEL" = "npm" ]; then
    "$BIN_DIR/codex" --version
else
    "$BIN_DIR/codex-$CODEX_SOURCE_VERSION" --version
    if [ "$CODEX_LINK_DEFAULT" = "1" ]; then
        "$BIN_DIR/codex" --version
    fi
fi
"$BIN_DIR/opencode" --version || warn "opencode --version returned non-zero"
"$BIN_DIR/dsh" --version

log "done"
printf '\nNode:     %s (%s) at %s\n' "$NODE_VER" "$NODE_ABI" "$NODE_PREFIX"
if [ "$CODEX_CHANNEL" = "npm" ]; then
    printf 'Codex:    npm %s (%s/codex)\n' "$CODEX_VERSION" "$BIN_DIR"
else
    printf 'Codex:    source %s (%s/codex-%s)\n' \
        "$CODEX_SOURCE_VERSION" "$BIN_DIR" "$CODEX_SOURCE_VERSION"
    if [ "$CODEX_LINK_DEFAULT" = "1" ]; then
        printf '          %s/codex also points at the source build\n' "$BIN_DIR"
    else
        printf '          %s/codex was not modified\n' "$BIN_DIR"
    fi
fi
if [ "$CODEX_CHANNEL" = "npm" ]; then
    printf 'Wrappers: %s/{codex,dsh,opencode}\n' "$BIN_DIR"
else
    printf 'Wrappers: %s/{dsh,opencode},%s/codex-%s\n' \
        "$BIN_DIR" "$BIN_DIR" "$CODEX_SOURCE_VERSION"
fi
printf 'Add %s to PATH if needed.\n' "$BIN_DIR"
