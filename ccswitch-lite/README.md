# ccswitch-lite

龙芯（loongarch64 / ABI2.0）原生的供应商切换工具，用来替代官方
[farion1231/cc-switch](https://github.com/farion1231/cc-switch) 在本机最常用的功能：

- 管理多套私有网关 profile（Anthropic / OpenAI 格式、模型映射、额外请求头）；
- 一键写入 **Claude Desktop 3P 网关配置**、**Claude Code** `settings.json`、**Codex CLI** `config.toml`；
- 一键恢复 Claude Desktop 官方 1P 模式；
- 内置零依赖 Web UI（`127.0.0.1:18081`），API Key 只显示掩码。

实现为单文件 Go 程序（stdlib only）+ 内嵌 HTML/JS；静态链接，除 glibc 外无运行时依赖。

## 仓库内容

| 内容 | 路径 |
| --- | --- |
| 源码 | `ccswitch-lite/`（`main.go`、`ui.go`、`go.mod`） |
| 测试 | `tests/test.sh`、`tests/desktop_test.sh`、`tests/mock_gateway.py`、`tests/cdp.mjs` |
| 构建产物 | `ccswitch-lite/ccswitch-lite`（不提交，已加入 `.gitignore`） |
| 安装示例 | 复制到 `/usr/local/bin/ccswitch`，数据在 `~/.config/ccswitch-lite/` |

重新构建：

```bash
cd ccswitch-lite
CGO_ENABLED=0 GOOS=linux GOARCH=loong64 \
  go build -trimpath -ldflags "-s -w" -o ccswitch-lite .
```

## 快速开始

```bash
# 添加一套私有网关（Anthropic 兼容）
ccswitch add \
  --name gw \
  --base-url https://api.example.com \
  --api-key sk-xxxx \
  --format anthropic \
  --default-model claude-sonnet-4-6 \
  --sonnet claude-sonnet-4-6 \
  --opus claude-opus-4-1 \
  --haiku claude-haiku-4-5 \
  --fable claude-fable-5

ccswitch use gw        # 设为当前并立即应用到三个目标
ccswitch list          # 查看列表（Key 掩码）
ccswitch apply         # 重新应用当前供应商
ccswitch restore       # Claude Desktop 回到 1P，并清理本工具写入项
ccswitch web           # 启动后输出 http://127.0.0.1:18081/?token=...
```

`add` 不带完整参数且运行在终端时会进入交互式提问。`--header "K=V"` 可重复，
目前只写入 Codex 的 `http_headers`（Claude Desktop / Claude Code 没有通用的自定义头配置位）。

## 数据模型

文件：`~/.config/ccswitch-lite/providers.json`（遵循 `XDG_CONFIG_HOME`，权限 0600）。

```json
{
  "current": "gw",
  "providers": [
    {
      "name": "gw",
      "baseUrl": "https://api.example.com",
      "apiKey": "sk-xxxx",
      "apiFormat": "anthropic",
      "defaultModel": "claude-sonnet-4-6",
      "models": {
        "sonnet": "claude-sonnet-4-6",
        "opus": "claude-opus-4-1",
        "haiku": "claude-haiku-4-5",
        "fable": "claude-fable-5"
      },
      "extraHeaders": {"X-Custom": "value"}
    }
  ],
  "applied": {"provider": "gw", "codexSlug": "ccswitch-gw", "wroteAuthKey": true, "at": "..."}
}
```

| 字段 | 说明 |
| --- | --- |
| `name` | 唯一名称；Codex 中会转成 slug `ccswitch-<name>` |
| `baseUrl` | 网关 API 根地址（**不要带 `/v1`**，见下文“baseUrl 语义”） |
| `apiKey` | 明文保存在 0600 文件；UI/CLI 只显示掩码 |
| `apiFormat` | `anthropic` 或 `openai`；写入三个目标时都会照写，格式不匹配会在输出中提示 |
| `defaultModel` | 写入 Claude Code 的 `ANTHROPIC_MODEL` |
| `models.sonnet/opus/haiku/fable` | 模型映射；`[1m]` 后缀会转成 Desktop 的 `supports1m` |
| `extraHeaders` | 仅 Codex 写出为 `[model_providers.<slug>.http_headers]` |
| `applied` | 内部状态：记录上次应用的 Codex slug，以及 auth.json 的 Key 是否由本工具写入 |

## 写入的目标

### 1. Claude Desktop（3P 网关）

严格按 cc-switch 的 3P 布局（XDG 默认 `~/.config`）：

| 文件 | 变更 |
| --- | --- |
| `~/.config/Claude/claude_desktop_config.json` | `deploymentMode = "3p"`，保留其他字段 |
| `~/.config/Claude-3p/claude_desktop_config.json` | `deploymentMode = "3p"`，保留其他字段 |
| `~/.config/Claude-3p/configLibrary/00000000-0000-4000-8000-000000157210.json` | 网关 profile |
| `~/.config/Claude-3p/configLibrary/_meta.json` | `entries` 加入 `{"id": "...157210", "name": "CC Switch"}`，`appliedId` 指向它 |

profile 内容：

```json
{
  "coworkEgressAllowedHosts": ["*"],
  "disableDeploymentModeChooser": true,
  "inferenceGatewayApiKey": "sk-xxxx",
  "inferenceGatewayAuthScheme": "bearer",
  "inferenceGatewayBaseUrl": "https://api.example.com",
  "inferenceProvider": "gateway",
  "inferenceModels": [
    {"name": "claude-sonnet-4-6"},
    {"name": "claude-opus-4-1"},
    {"name": "claude-haiku-4-5"},
    {"name": "claude-fable-5"}
  ]
}
```

- `coworkEgressAllowedHosts: ["*"]` 允许 Desktop 内的 Cowork 访问任意出站主机，这是 cc-switch 的既有行为；
  如安全策略更严，应改为显式主机列表。
- 配置了模型映射才会写 `inferenceModels`；某项模型名带 `[1m]` 时，去掉后缀并写
  `supports1m: true` + `prefer1m: true`。重复模型名会去重。
- Desktop 启动日志会显示 `3P mode active`、`Model discovery: skipped (inferenceModels obviates discovery)`，
  说明 profile 被正确读取。

### 2. Claude Code

`~/.claude/settings.json`（或 `$CLAUDE_CONFIG_DIR/settings.json`）的 `env` 写入：

- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_AUTH_TOKEN`
- 可选：`ANTHROPIC_MODEL`、`ANTHROPIC_DEFAULT_{SONNET,OPUS,HAIKU,FABLE}_MODEL`

只增删本工具拥有的 7 个键，保留 `permissions` 等其他设置和无关 `env` 变量。

### 3. Codex CLI

`~/.codex/config.toml`（或 `$CODEX_HOME/config.toml`）文本合并：

```toml
model_provider = "ccswitch-gw"

[model_providers.ccswitch-gw]
name = "gw"
base_url = "https://api.example.com"
env_key = "OPENAI_API_KEY"
wire_api = "responses"
```

- 保留原有 TOML 的顶层键、其他表、`[[数组表]]`、多行数组和注释；
- 重复 apply 不会产生重复表；
- `auth.json`：若不存在或没有 `OPENAI_API_KEY`，写入当前 Key；若已有非空 Key，**不覆盖**。
  如果该 Key 是上一次由本工具写入的，则允许随供应商切换更新，`restore` 时也会移除；
- Codex 需要的是 OpenAI Responses 协议端点；`apiFormat=openai` 更匹配。

## baseUrl 语义（实测）

Claude Desktop 使用的 Anthropic SDK 会在 `inferenceGatewayBaseUrl` 后追加 `/v1/messages`。
因此 **baseUrl 应填 API 根地址（不含 `/v1`）**。例如网关的 Anthropic 端点是
`https://api.example.com/v1/messages`，则 baseUrl 填 `https://api.example.com`。

验收时按要求使用了 `http://127.0.0.1:18080/v1`，Desktop 实际请求为
`POST /v1/v1/messages`（mock 接受任意路径）。这是 baseUrl 含 `/v1` 导致的重复，
不是工具拼接错误。Claude Code 的 `ANTHROPIC_BASE_URL` 语义相同。

## 备份与恢复

- 每次写文件前生成 `<原文件>.bak.<YYYYMMDD-HHMMSS.nnnnnnnnn>`，与源文件同目录；
- 所有写操作先做预检：任一目标 JSON/TOML 已损坏则整体中止，不写入任何文件；
- 写入后立即回读校验，失败自动从本次备份回滚；
- `ccswitch restore`：
  - 两个 Desktop `claude_desktop_config.json` 的 `deploymentMode` 改回 `"1p"`；
  - `_meta.json` 移除 `...157210` 条目；若 `appliedId` 指向它，则回退到剩余第一个条目，没有则删除；
  - 移除 Claude Code 中本工具写入的 7 个 env 键；
  - 移除本工具的 Codex provider 表与 `model_provider`（仅当原值是本工具写入的）；
  - 若 `auth.json` 的 Key 确由本工具写入，则移除该键；
  - 不删除 profile 文件本身，也不恢复切换前的第三方 `model_provider` 旧值；需要完全回滚时直接使用 `.bak.*` 备份。

## Web UI

`ccswitch web [--addr 127.0.0.1:18081]`

- 仅允许回环地址（`127.0.0.1`/`::1`/`localhost`），拒绝 `0.0.0.0`，防止 API Key 管理界面暴露到网络；
- 启动时生成 32 字节 capability token，写入 `~/.config/ccswitch-lite/web-token`（0600）；打开启动命令输出的 `?token=...` URL，UI 会把 token 移入 sessionStorage 并从地址栏移除；
- `/api/*` 必须携带 `X-CCSwitch-Token`（或 `Authorization: Bearer`）；其他本机用户读不到 0600 token 文件，因此不能调用 API。自动化可设置 `CCSWITCH_WEB_TOKEN`（至少 16 字符）；
- 所有请求校验 `Host` 必须是回环地址；写请求必须是 `Content-Type: application/json`，且 `Origin`（如有）必须是回环地址。这样任意网页无法用跨站表单或 `text/plain` 请求改写供应商并诱导 Key 外泄，DNS rebinding 也会被 Host 检查拦下；
- GET `/api/state` 返回供应商列表与 `maskedKey`，从不返回完整 Key；
- 支持新增/编辑/删除、使用并应用、应用当前、恢复官方；
- 无外部 JS/CSS/字体依赖，离线可用。

## 验收结果（2026-10-18）

完整验收：`bash tests/test.sh`（86 条 PASS，退出码 0）。测试在一次性
`HOME=/tmp/ccswitch-test/home` 中运行，未触碰真实 `~/.claude`、`~/.codex`。

覆盖内容：

- 4 个 Claude Desktop 文件的实际内容、字段保留、`inferenceModels`、`_meta.json` 合并；
- Claude Code `env` 7 个键写入/移除、无关变量与 `permissions` 保留；
- Codex TOML 用 Python `tomllib` 实际解析，验证 `model_provider`、provider 字段、
  `env_key`、`wire_api`、`http_headers`，并保留 `projects`、`mcp_servers`（多行数组）、
  `[[plugins]]` 数组表；二次 apply 无重复表；
- 13 个 `.bak.<timestamp>` 备份均非空；
- Web 首页 HTTP 200，`/api/state` 中无完整 Key，`/api/use` 返回 ok；
- `restore` 后 deploymentMode 回到 1p、profile 条目移除、`appliedId` 回退、
  Claude Code/Codex/auth.json 清理；
- 损坏 JSON 时 apply 拒绝执行且原文件哈希不变；
- 在 fake → fake2 切换后，旧 `ccswitch-*` provider 表被清除、`model_provider` 更新、
  本工具写入的 auth.json Key 随之更新；再次 restore 后全部清除。

### Claude Desktop 3P 实测

在隔离的 `HOME=/tmp/ccswitch-desktop/home` 下启动重打包的 Claude Desktop
（重打包的 Claude Desktop，Xvfb + openbox），mock 网关监听 `127.0.0.1:18080`：

- App 日志：
  - `Credentials loaded from managed config { provider: 'gateway' }`
  - `3P mode active { provider: 'gateway' }`
  - `Model discovery: skipped (inferenceModels obviates discovery); picker = 4 (inferenceModels)`
  - `ConfigHealth recomputed { state: 'healthy', provider: 'gateway' }`
  - `inference apiHost=http://127.0.0.1:18080/v1`
- Mock 收到启动健康探测请求：
  `POST /v1/v1/messages`，`authorization: Bearer test-key`，
  `{"model":"claude-haiku-4-5","max_tokens":1,...}`。
- 界面显示 `You're using Gateway`，模型菜单显示 `Sonnet 4.6`。

结论：**3P 网关配置确实生效，请求确实打到了配置的 mock 地址，并使用配置的 Key**。
截图与日志见 `logs/desktop-gateway-mode.png`、`logs/desktop-mock.log`、
`logs/desktop-3p-evidence.log`。

未能完成一次完整的聊天往返：这个重打包的 Desktop 在 Code/Cowork 会话里会下载并启动
**x86-64 版内置 Claude Code**（`claude-code/2.1.299/.../claude` 是 ELF x86-64），
在 LoongArch 上以 code 1 退出；界面同时提示 “Cowork requires a supported CPU architecture
on Linux”。这是 Desktop 自身在 LoongArch 上的限制，与 ccswitch-lite 的配置写入无关。

## 限制

- API Key 以明文存储于 0600 的 `providers.json`，未接系统钥匙串；
- 自定义请求头只支持 Codex；Claude Desktop/Claude Code 无对应配置位；
- Claude Desktop 模型名建议保持 `claude-*` 形式，非 Claude 名称可能被 Desktop 的校验器拒绝；
- `restore` 是“撤销本工具写入”，不是时间机器；完整回滚请用 `.bak.*`；
- JSON 文件会被重新序列化（缩进 2 空格、键顺序变化），语义与字段内容保持不变；
- Web UI 无用户鉴权，仅绑定回环地址，并拒绝非回环 Host/跨站 Origin/非 JSON 写请求。

## 官方 cc-switch 的 Tauri 移植结论（已更正）

早期“未移植、ring 硬阻塞”的结论**已被实测推翻**：

- 官方 cc-switch **v4.0.19** 已在 loongarch64 上用 **Rust 1.97.1 直接构建成功**；
- `ring 0.17.14` 能正常编译；其 `build.rs` 的 `panic!("unsupported arch")`
  只在 Windows x86 的 NASM 路径触发，Linux loong64 构建不会走到；
- 构建命令必须带 `--features tauri/custom-protocol`，否则 webview 仍指向
  `devUrl` 的 `localhost:3000`；
- 官方完整 UI（Claude Code / Claude Desktop / Codex / Gemini / OpenCode /
  MCP / Skills / Prompts 等）已在 Xvfb 下验证。

私有移植仓库：<https://github.com/yunix-intel/cc-switch-loongarch>；
构建、runner 与 `.deb` 细节见 `docs/cc-switch-loongarch.md`。
`ccswitch-lite` 仍作为轻量、stdlib-only 的替代方案保留。
