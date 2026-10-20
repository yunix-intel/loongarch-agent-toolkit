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
# Overridable environment:
#   NODE_VERSION=22.23.3
#   NODE_PREFIX=/opt/node22-abi2
#   NPM_REGISTRY=https://registry.loongnix.cn:5873
#   CODEX_VERSION=0.162.0
#   OPENCODE_VERSION=1.19.0
#   DSH_VERSION=latest
#   BIN_DIR=/usr/local/bin
#   NODE_URL=<explicit tarball URL>
#   ALLOW_ABI1=1   # force installation on an ABI1.0 userspace (not recommended)

set -eu

log() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"

ARCH=$(uname -m)
case "$ARCH" in
    loongarch64|loong64) ;;
    *) die "this script targets LoongArch, got: $ARCH" ;;
esac

NODE_VERSION=${NODE_VERSION:-22.23.3}
NODE_PREFIX=${NODE_PREFIX:-/opt/node22-abi2}
NPM_REGISTRY=${NPM_REGISTRY:-https://registry.loongnix.cn:5873}
CODEX_VERSION=${CODEX_VERSION:-0.162.0}
OPENCODE_VERSION=${OPENCODE_VERSION:-1.19.0}
DSH_VERSION=${DSH_VERSION:-latest}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
NODE_URL=${NODE_URL:-https://github.com/loong64/node/releases/download/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-loong64.tar.xz}

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

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

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

if curl -fsSL --retry 2 -o "$TMP/$NODE_TARBALL.sha256" "$NODE_URL.sha256"; then
    ( cd "$TMP" && sha256sum -c "$NODE_TARBALL.sha256" ) || die "Node checksum mismatch"
else
    warn "no .sha256 asset found; skipping checksum verification"
fi

mkdir -p "$TMP/node"
tar -xJf "$TMP/$NODE_TARBALL" -C "$TMP/node" --strip-components=1

if [ -e "$NODE_PREFIX" ]; then
    BACKUP="$NODE_PREFIX.bak.$(date +%Y%m%d-%H%M%S)"
    log "moving existing $NODE_PREFIX to $BACKUP"
    mv "$NODE_PREFIX" "$BACKUP"
fi
mkdir -p "$(dirname "$NODE_PREFIX")"
mv "$TMP/node" "$NODE_PREFIX"

[ -x "$NODE_PREFIX/bin/node" ] || die "Node install failed: $NODE_PREFIX/bin/node missing"
NODE_ABI=$(abi_name "$(elf_flags "$NODE_PREFIX/bin/node")")
NODE_VER=$("$NODE_PREFIX/bin/node" -v)
log "installed Node $NODE_VER at $NODE_PREFIX ($NODE_ABI)"
[ "$NODE_ABI" = "ABI2.0" ] || die "downloaded Node is $NODE_ABI, expected ABI2.0"

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
    log "installing $pkg@$version from $NPM_REGISTRY"
    "$NPM" install -g \
        --prefix "$NODE_PREFIX" \
        --registry "$NPM_REGISTRY" \
        --fetch-retries 3 \
        --no-audit --no-fund \
        "$pkg@$version"
}

install_pkg "@openai/codex" "$CODEX_VERSION"
install_pkg "opencode-ai" "$OPENCODE_VERSION"
install_pkg "@deepseek-ai/dsh" "$DSH_VERSION"

CODEX_JS="$NODE_PREFIX/lib/node_modules/@openai/codex/bin/codex.js"
DSH_JS="$NODE_PREFIX/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
OPENCODE_BIN="$NODE_PREFIX/lib/node_modules/opencode-ai/bin/opencode.exe"

[ -f "$CODEX_JS" ] || die "codex entrypoint not found: $CODEX_JS"
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

cat > "$BIN_DIR/codex" <<EOF
#!/bin/sh
# generated by install-loongarch-agents.sh
exec "$NODE_PREFIX/bin/node" "$CODEX_JS" "\$@"
EOF

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

chmod 0755 "$BIN_DIR/codex" "$BIN_DIR/dsh" "$BIN_DIR/opencode"

log "verifying wrappers"
"$BIN_DIR/codex" --version
"$BIN_DIR/opencode" --version || warn "opencode --version returned non-zero"
"$BIN_DIR/dsh" --version

log "done"
printf '\nNode:     %s (%s) at %s\n' "$NODE_VER" "$NODE_ABI" "$NODE_PREFIX"
printf 'Wrappers: %s/{codex,dsh,opencode}\n' "$BIN_DIR"
printf 'Add %s to PATH if needed.\n' "$BIN_DIR"
