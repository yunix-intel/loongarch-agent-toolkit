#!/bin/bash
# Bring up a throwaway HOME + Xvfb + mock gateway + Claude Desktop with the
# 3P profile written by ccswitch-lite.
#
# This is an optional end-to-end probe; it is not part of CI. It expects an
# already-installed Claude Desktop and Xvfb.
#
# Usage: desktop_test.sh [start|stop|probe]
# Env:
#   CLAUDE_DESKTOP_APP=/opt/claude-desktop/claude-desktop
#   BIN=<repo>/ccswitch-lite/ccswitch-lite
#   MOCK_GATEWAY=<repo>/ccswitch-lite/tests/mock_gateway.py
set -uo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BASE=${BASE:-/tmp/ccswitch-desktop}
APP=${CLAUDE_DESKTOP_APP:-/opt/claude-desktop/claude-desktop}
BIN=${BIN:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)/ccswitch-lite}
MOCK_GATEWAY=${MOCK_GATEWAY:-$SCRIPT_DIR/mock_gateway.py}
export HOME="$BASE/home"
export XDG_CONFIG_HOME="$HOME/.config"
export DISPLAY=:99

stop_all() {
  [ -f "$BASE/app.pid" ] && kill "$(cat "$BASE/app.pid")" 2>/dev/null
  [ -f "$BASE/xvfb.pid" ] && kill "$(cat "$BASE/xvfb.pid")" 2>/dev/null
  [ -f "$BASE/mock.pid" ] && kill "$(cat "$BASE/mock.pid")" 2>/dev/null
  pkill -f "$APP" 2>/dev/null
  pkill -f mock_gateway.py 2>/dev/null
  pkill -f "Xvfb :99" 2>/dev/null
  rm -f "$BASE/app.pid" "$BASE/xvfb.pid" "$BASE/mock.pid"
}

case "${1:-start}" in
start)
  stop_all
  rm -rf "$BASE"
  mkdir -p "$HOME/.config/Claude" "$HOME/.config/Claude-3p" "$HOME/logs"
  # Reuse harmless first-launch metadata so the app does not treat this as a
  # brand-new install. This reads the real config but never writes to it.
  cp "${REAL_CLAUDE_CONFIG:-/root/.config/Claude/config.json}" "$HOME/.config/Claude/config.json" 2>/dev/null || true
  mkdir -p "$HOME/.config/Claude-3p/configLibrary"

  "$BIN" add --name mock --base-url http://127.0.0.1:18080/v1 --api-key test-key \
    --format anthropic --default-model claude-sonnet-4-6 \
    --sonnet claude-sonnet-4-6 --opus claude-opus-4-1 \
    --haiku claude-haiku-4-5 --fable claude-fable-5 >"$BASE/ccswitch-add.log" 2>&1
  "$BIN" apply >"$BASE/ccswitch-apply.log" 2>&1
  echo "deploymentMode files:"
  cat "$HOME/.config/Claude/claude_desktop_config.json"
  cat "$HOME/.config/Claude-3p/claude_desktop_config.json"

  MOCK_LOG="$BASE/mock.log" nohup python3 "$MOCK_GATEWAY" >"$BASE/mock-server.log" 2>&1 &
  echo $! > "$BASE/mock.pid"

  Xvfb :99 -screen 0 1600x1000x24 >"$BASE/xvfb.log" 2>&1 &
  echo $! > "$BASE/xvfb.pid"
  sleep 1

  ( cd "$(dirname "$APP")" && \
    HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" DISPLAY=:99 \
    ELECTRON_DISABLE_SECURITY_WARNINGS=1 NO_AT_BRIDGE=1 \
    nohup "$APP" --no-sandbox --disable-gpu --disable-dev-shm-usage \
      >"$BASE/app.log" 2>&1 & echo $! > "$BASE/app.pid" )
  echo "started: mock=$(cat "$BASE/mock.pid") xvfb=$(cat "$BASE/xvfb.pid") app=$(cat "$BASE/app.pid")"
  ;;
stop)
  stop_all
  echo stopped
  ;;
probe)
  echo "== processes =="
  ps -o pid,etime,cmd -p "$(cat "$BASE/app.pid" 2>/dev/null)" 2>/dev/null
  echo "== CDP targets =="
  curl -s --max-time 3 http://127.0.0.1:9222/json | head -c 2000
  echo
  echo "== app log tail =="
  tail -30 "$BASE/app.log" 2>/dev/null
  echo "== mock log =="
  tail -20 "$BASE/mock.log" 2>/dev/null
  ;;
*)
  echo "usage: $0 [start|stop|probe]"
  exit 2
  ;;
esac
