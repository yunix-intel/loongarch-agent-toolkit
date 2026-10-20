#!/usr/bin/env bash
# check-agent-versions.sh
#
# Compare the version pins in install/install-loongarch-agents.sh with:
#   * the upstream npm registry (registry.npmjs.org)
#   * the Loongnix registry (registry.loongnix.cn:5873), restricted to
#     loong64-capable builds
#
# Outputs (in the current directory by default):
#   version-table.md  Markdown table for the job step summary
#   issue-body.md     Issue body used by agent-version-watch.yml
#
# When GITHUB_OUTPUT is set, writes `needs_issue=true|false`.
#
# This script never edits the installer and never installs anything.

set -euo pipefail

INSTALLER=${INSTALLER:-install/install-loongarch-agents.sh}
OUT_TABLE=${OUT_TABLE:-version-table.md}
OUT_BODY=${OUT_BODY:-issue-body.md}
UPSTREAM_REGISTRY=${UPSTREAM_REGISTRY:-https://registry.npmjs.org}
LOONG_REGISTRY=${LOONG_REGISTRY:-https://registry.loongnix.cn:5873}
TODAY=${TODAY:-$(date -u +%Y-%m-%d)}

warn() { printf 'warning: %s\n' "$*" >&2; }

need() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'error: missing required command: %s\n' "$1" >&2
        exit 1
    }
}

need curl
need jq
need sort

[ -f "$INSTALLER" ] || {
    printf 'error: installer not found: %s\n' "$INSTALLER" >&2
    exit 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-version-watch.XXXXXX")
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT HUP INT TERM

# Read VAR=${VAR:-value} (or VAR=value) from the installer.
pin_of() {
    local var=$1 line value
    line=$(grep -E "^${var}=" "$INSTALLER" | head -n 1 | cut -d= -f2- || true)
    [ -n "$line" ] || {
        printf 'error: %s not found in %s\n' "$var" "$INSTALLER" >&2
        exit 1
    }
    case "$line" in
        '${'*'}')
            value=${line#*:-}
            value=${value%\}}
            ;;
        *) value=$line ;;
    esac
    printf '%s' "$value"
}

fetch() {
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 180 "$1" -o "$2"
}

# Upstream `latest` version for an already URL-encoded package name.
upstream_latest() {
    local pkg=$1 file
    file="$TMP/upstream-$(printf '%s' "$pkg" | tr -c 'A-Za-z0-9' '_').json"
    if fetch "$UPSTREAM_REGISTRY/$pkg/latest" "$file"; then
        jq -r '.version // empty' "$file"
    else
        warn "failed to query $UPSTREAM_REGISTRY/$pkg/latest"
        printf ''
    fi
}

# Highest @openai/codex version that has a -linux-loong64 build.
codex_loong_latest() {
    local file="$TMP/codex.json" version
    if ! fetch "$LOONG_REGISTRY/@openai%2Fcodex" "$file"; then
        warn "failed to query $LOONG_REGISTRY/@openai%2Fcodex"
        printf ''
        return 0
    fi
    version=$(jq -r '.versions | keys[]
        | select(endswith("-linux-loong64"))
        | sub("-linux-loong64$"; "")' "$file" | sort -V | tail -n 1 || true)
    printf '%s' "$version"
}

# OpenCode ships its loong64 build as a separate package.
opencode_loong_latest() {
    local file="$TMP/opencode.json"
    if ! fetch "$LOONG_REGISTRY/opencode-linux-loong64" "$file"; then
        warn "failed to query $LOONG_REGISTRY/opencode-linux-loong64"
        printf ''
        return 0
    fi
    jq -r '."dist-tags".latest // empty' "$file"
}

# DSH is architecture-independent; the registry latest is the loong64 one.
dsh_loong_latest() {
    local file="$TMP/dsh.json"
    if ! fetch "$LOONG_REGISTRY/@deepseek-ai%2Fdsh" "$file"; then
        warn "failed to query $LOONG_REGISTRY/@deepseek-ai%2Fdsh"
        printf ''
        return 0
    fi
    jq -r '."dist-tags".latest // empty' "$file"
}

le() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$2" ]
}

status_of() {
    local pin=$1 loong=$2 upstream=$3
    if [ -z "$loong" ] || [ -z "$upstream" ]; then
        printf '查询失败'
        return
    fi
    if [ "$pin" = latest ]; then
        if [ "$upstream" = "$loong" ]; then
            printf '已最新'
        else
            printf '等待移植'
        fi
        return
    fi
    if [ "$pin" = "$loong" ]; then
        if [ "$upstream" = "$loong" ]; then
            printf '已最新'
        else
            printf '等待移植'
        fi
    elif le "$pin" "$loong"; then
        printf '可升级'
    else
        printf '需人工确认'
    fi
}

show_pin() {
    if [ "$1" = latest ]; then
        printf '`latest`（自动跟随）'
    else
        printf '`%s`' "$1"
    fi
}

show_ver() {
    if [ -n "$1" ]; then printf '`%s`' "$1"; else printf '-'; fi
}

CODEX_PIN=$(pin_of CODEX_VERSION)
OPENCODE_PIN=$(pin_of OPENCODE_VERSION)
DSH_PIN=$(pin_of DSH_VERSION)

CODEX_UP=$(upstream_latest '@openai%2Fcodex')
OPENCODE_UP=$(upstream_latest 'opencode-ai')
DSH_UP=$(upstream_latest '@deepseek-ai%2Fdsh')

CODEX_LOONG=$(codex_loong_latest)
OPENCODE_LOONG=$(opencode_loong_latest)
DSH_LOONG=$(dsh_loong_latest)

CODEX_STATUS=$(status_of "$CODEX_PIN" "$CODEX_LOONG" "$CODEX_UP")
OPENCODE_STATUS=$(status_of "$OPENCODE_PIN" "$OPENCODE_LOONG" "$OPENCODE_UP")
DSH_STATUS=$(status_of "$DSH_PIN" "$DSH_LOONG" "$DSH_UP")

NEEDS_ISSUE=false
case "$CODEX_STATUS $OPENCODE_STATUS $DSH_STATUS" in
    *可升级* | *等待移植* | *查询失败* | *需人工确认*) NEEDS_ISSUE=true ;;
esac

{
    printf '| 工具 | 已 pin | 上游 latest | loong64 可用 latest | 状态 |\n'
    printf '| --- | --- | --- | --- | --- |\n'
    printf '| Codex (`@openai/codex`) | %s | %s | %s | %s |\n' \
        "$(show_pin "$CODEX_PIN")" "$(show_ver "$CODEX_UP")" \
        "$(show_ver "$CODEX_LOONG")" "$CODEX_STATUS"
    printf '| OpenCode (`opencode-ai`) | %s | %s | %s | %s |\n' \
        "$(show_pin "$OPENCODE_PIN")" "$(show_ver "$OPENCODE_UP")" \
        "$(show_ver "$OPENCODE_LOONG")" "$OPENCODE_STATUS"
    printf '| DSH (`@deepseek-ai/dsh`) | %s | %s | %s | %s |\n' \
        "$(show_pin "$DSH_PIN")" "$(show_ver "$DSH_UP")" \
        "$(show_ver "$DSH_LOONG")" "$DSH_STATUS"
} > "$OUT_TABLE"

RUN_URL=''
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
    RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

{
    printf '<!-- agent-version-watch -->\n'
    printf '@yunix-intel LoongArch agent 版本检查发现需要关注的变化（%s UTC）。\n\n' "$TODAY"
    cat "$OUT_TABLE"
    printf '\n'

    commands=''
    if [ "$CODEX_STATUS" = 可升级 ]; then
        commands="${commands}sudo CODEX_VERSION=${CODEX_LOONG} ./install/install-loongarch-agents.sh"$'\n'
    fi
    if [ "$OPENCODE_STATUS" = 可升级 ]; then
        commands="${commands}sudo OPENCODE_VERSION=${OPENCODE_LOONG} ./install/install-loongarch-agents.sh"$'\n'
    fi
    if [ "$DSH_STATUS" = 可升级 ]; then
        commands="${commands}sudo DSH_VERSION=${DSH_LOONG} ./install/install-loongarch-agents.sh"$'\n'
    fi

    if [ -n "$commands" ]; then
        printf '### 升级命令\n\n```sh\n%s```\n\n' "$commands"
    fi

    notes=''
    if [ "$CODEX_STATUS" = 等待移植 ]; then
        notes="${notes}- Codex：上游 ${CODEX_UP}，Loongnix 的 \`@openai/codex\` 最新 loong64 构建是 ${CODEX_LOONG}，等待移植。"$'\n'
    fi
    if [ "$OPENCODE_STATUS" = 等待移植 ]; then
        notes="${notes}- OpenCode：上游 ${OPENCODE_UP}，\`opencode-linux-loong64\` 最新是 ${OPENCODE_LOONG}，等待移植。"$'\n'
    fi
    if [ "$DSH_STATUS" = 等待移植 ]; then
        notes="${notes}- DSH：上游 ${DSH_UP}，Loongnix 最新是 ${DSH_LOONG}，等待同步。"$'\n'
    fi
    if [ "$CODEX_STATUS" = 查询失败 ] || [ "$OPENCODE_STATUS" = 查询失败 ] || [ "$DSH_STATUS" = 查询失败 ]; then
        notes="${notes}- 有 registry 查询失败，请查看 workflow 日志。"$'\n'
    fi
    if [ -n "$notes" ]; then
        printf '### 说明\n\n%s\n' "$notes"
    fi

    printf '本 issue 由 `.github/workflows/agent-version-watch.yml` 自动创建/更新；'
    printf 'workflow 只检测版本，不会修改 `install/` 中的 pin，也不会自动安装。\n'
    if [ -n "$RUN_URL" ]; then
        printf '\n运行记录：%s\n' "$RUN_URL"
    fi
} > "$OUT_BODY"

cat "$OUT_TABLE"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf 'needs_issue=%s\n' "$NEEDS_ISSUE" >> "$GITHUB_OUTPUT"
fi
