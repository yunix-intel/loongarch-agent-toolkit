#!/bin/sh
# install-claude-code-loongarch.sh
#
# Install the last pure-JavaScript Claude Code release (2.1.112) on LoongArch.
# Native Claude Code builds (>= 2.1.113) do not ship a linux-loong64 artifact.
#
# Usage:
#   sudo ./install-claude-code-loongarch.sh
#
# Overridable:
#   CLAUDE_CODE_VERSION=2.1.112
#   CLAUDE_CODE_NPM_REGISTRY=https://registry.npmjs.org
#   CLAUDE_CODE_PREFIX=/opt/claude-code
#   CLAUDE_CODE_NODE=/opt/node26/bin/node
#   CLAUDE_CODE_LINK_DEFAULT=1
#   BIN_DIR=/usr/local/bin
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
    fi
    printf '%s' "${value:-$fallback}"
}

[ "$(id -u)" -eq 0 ] || die "run as root: sudo $0"
case "$(uname -m)" in
    loongarch64|loong64) ;;
    *) die "this script targets LoongArch, got: $(uname -m)" ;;
esac

CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION:-$(manifest_get CLAUDE_CODE_VERSION 2.1.112)}
CLAUDE_CODE_NPM_REGISTRY=${CLAUDE_CODE_NPM_REGISTRY:-$(manifest_get CLAUDE_CODE_NPM_REGISTRY https://registry.npmjs.org)}
CLAUDE_CODE_PREFIX=${CLAUDE_CODE_PREFIX:-$(manifest_get CLAUDE_CODE_PREFIX /opt/claude-code)}
CLAUDE_CODE_NODE=${CLAUDE_CODE_NODE:-$(manifest_get CLAUDE_CODE_NODE '')}
CLAUDE_CODE_LINK_DEFAULT=${CLAUDE_CODE_LINK_DEFAULT:-$(manifest_get CLAUDE_CODE_LINK_DEFAULT 1)}
BIN_DIR=${BIN_DIR:-/usr/local/bin}

case "$CLAUDE_CODE_VERSION" in
    *[!0-9A-Za-z._-]*) die "invalid CLAUDE_CODE_VERSION: $CLAUDE_CODE_VERSION" ;;
esac
case "$CLAUDE_CODE_PREFIX" in
    /*) ;;
    *) die "CLAUDE_CODE_PREFIX must be an absolute path" ;;
esac
case "$CLAUDE_CODE_LINK_DEFAULT" in
    0|1) ;;
    *) die "CLAUDE_CODE_LINK_DEFAULT must be 0 or 1" ;;
esac

need install

if [ -z "$CLAUDE_CODE_NODE" ]; then
    for candidate in /opt/node26/bin/node /opt/node24/bin/node /opt/node22-abi2/bin/node; do
        if [ -x "$candidate" ]; then CLAUDE_CODE_NODE=$candidate; break; fi
    done
fi
if [ -z "$CLAUDE_CODE_NODE" ] || [ ! -x "$CLAUDE_CODE_NODE" ]; then
    die "no Node.js runtime found; set CLAUDE_CODE_NODE"
fi

NODE_DIR=$(dirname "$CLAUDE_CODE_NODE")
NPM="$NODE_DIR/npm"
[ -x "$NPM" ] || NPM=$(command -v npm || true)
if [ -z "$NPM" ] || [ ! -x "$NPM" ]; then
    die "npm not found next to $CLAUDE_CODE_NODE or on PATH; install npm or set CLAUDE_CODE_NODE"
fi
PATH="$NODE_DIR:$PATH"
export PATH

log "installing @anthropic-ai/claude-code@$CLAUDE_CODE_VERSION into $CLAUDE_CODE_PREFIX"
if [ -e "$CLAUDE_CODE_PREFIX" ]; then
    BACKUP="$CLAUDE_CODE_PREFIX.bak.$(date +%Y%m%d-%H%M%S)"
    log "moving existing $CLAUDE_CODE_PREFIX to $BACKUP"
    mv "$CLAUDE_CODE_PREFIX" "$BACKUP"
fi
mkdir -p "$CLAUDE_CODE_PREFIX"

"$NPM" install -g \
    --prefix "$CLAUDE_CODE_PREFIX" \
    --registry "$CLAUDE_CODE_NPM_REGISTRY" \
    --fetch-retries 3 \
    --no-audit --no-fund \
    "@anthropic-ai/claude-code@$CLAUDE_CODE_VERSION"

CLI="$CLAUDE_CODE_PREFIX/lib/node_modules/@anthropic-ai/claude-code/cli.js"
[ -f "$CLI" ] || die "Claude Code cli.js not found at $CLI"

# The official npm package has native-only releases after 2.1.112.  Pin this
# wrapper to the JS entrypoint and disable the self-updater so it cannot pull a
# native-only release over the working copy.
if [ "$CLAUDE_CODE_LINK_DEFAULT" = "1" ]; then
    wrapper="$BIN_DIR/claude"
else
    wrapper="$BIN_DIR/claude-${CLAUDE_CODE_VERSION}"
fi
mkdir -p "$BIN_DIR"
cat > "$wrapper" <<EOF
#!/bin/sh
export USE_BUILTIN_RIPGREP=0
export DISABLE_AUTOUPDATER=1
exec "$CLAUDE_CODE_NODE" "$CLI" "\$@"
EOF
chmod 0755 "$wrapper"
log "installed $wrapper -> $CLI (Node $("$CLAUDE_CODE_NODE" -v))"

"$CLAUDE_CODE_NODE" "$CLI" --version
