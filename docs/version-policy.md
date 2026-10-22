# Agent 版本选择策略

[`install/versions.env`](../install/versions.env) 是版本管理的单一事实源。
`install/install-loongarch-agents.sh`、README 的版本表和
`.github/workflows/agent-version-watch.yml` 都以它为准。CI 会检查三者是否
一致，任何一处手改后忘记同步都会失败。

## selected ≠ upstream latest

`selected` 的定义是**当前 LoongArch 上实际可用的最新版**，不一定是上游
`latest`：

| 工具 | selected 来源 | 上游领先时的状态 |
| --- | --- | --- |
| Codex (npm) | Loongnix registry 中最新的 `@openai/codex-<ver>-linux-loong64` | `waiting-for-loong64-port` |
| Codex (source) | 私有 builds 仓库中最新 `codex-rust-v<ver>-loongarch64.tar.gz`；仅在 `CODEX_CHANNEL=source` 时作为默认通道 | `source-private` / `source-available` |
| OpenCode | `opencode-linux-loong64` 的 `latest` | `waiting-for-loong64-port` |
| DSH | Loongnix registry 的 `@deepseek-ai/dsh@latest` | `waiting-upstream-sync` |
| Claude Code | npm 上**最后一个仍包含 `cli.js`** 的版本 | `native-only` |
| ZCode | `zai-org/ZCode` 的最新 semver tag | `tag-ahead-of-release` |
| cc-switch | `farion1231/cc-switch` 的最新 GitHub release | `up-to-date` |

只有当 Loongnix（或源码构建）真的产出了 loong64 版本，workflow 才会把
对应通道的 selected 往上调。上游发了新版但没有 loong64 构建时，issue 会标注
`waiting-for-loong64-port`，不会产生 npm 升级 PR。

## Codex 的 npm 与 source 通道

`install/versions.env` 同时记录两条通道：

- `CODEX_CHANNEL=npm|source`（默认 `npm`）；
- `CODEX_VERSION`：npm 通道版本；
- `CODEX_SOURCE_VERSION` / `CODEX_SOURCE_URL` / `CODEX_SOURCE_SHA256`：
  源码构建的版本、资产 URL（可为空，安装时用环境变量补）和 SHA-256；
- `CODEX_LINK_DEFAULT=0|1`：是否让默认 `codex` 也指向源码构建。

安装器在 npm 通道仍安装 `@openai/codex@CODEX_VERSION`。source 通道把归档解到
`/opt/codex-<version>`（可用 `CODEX_SOURCE_PREFIX` 改前缀），写
`/usr/local/bin/codex-<version>`；只有 `CODEX_LINK_DEFAULT=1` 才覆盖默认
`codex`。`CODEX_SOURCE_URL` 支持 `http(s)://` 或本地 `.tar.gz`；私有 GitHub
release 资产需 `CODEX_SOURCE_TOKEN`（或 `GITHUB_TOKEN`），URL 用 API asset
地址（draft release 不能用 `browser_download_url`）。解包前校验 SHA-256，
并拒绝绝对路径/`..` 条目。

`AUTO_ALIGN_TOKEN` 配置后，watch 会用该 token 读取 builds 仓库（含 draft
release），发现更高版本时同步更新上述三个 source 字段；没有 token 时 issue
标注 `source build available (private; set AUTO_ALIGN_TOKEN or URL)`，不会
改动 npm pin。

## Claude Code：native-only 之后不再自动升级

从 2.1.113 起，`@anthropic-ai/claude-code` 的 npm tarball 只包含
`cli-wrapper.cjs` / `install.cjs` / `bin/claude.exe` 等原生安装器，不再有
`cli.js`。这种包在 LoongArch 上只能靠 box64 跑 x86-64 二进制，不属于本仓库
支持的 ABI2.0 原生路径。

因此 workflow 会从 npm 版本列表**二分查找**最后一个带 `cli.js` 的版本
（当前为 2.1.112），把它作为 selected；更新的版本只在 issue 中标注
`native-only / box64-only`，不会自动写入清单。如果将来上游恢复 JS 入口，二分
查找会自动把 selected 抬到那个版本。

## ZCode：跟 tag，不跟 GitHub release

`zai-org/ZCode` 的 GitHub release 页面滞后于实际的 semver tag（当前 tag
`v3.15.1`，release 仍是 `v3.14.3`）。ZCode 的可用版本以 tag 为准，所以
selected 取 tag 的最大 semver；release tag 只作为 “upstream” 列展示，并在
落后时标记 `tag-ahead-of-release`。

`install/versions.env` 还记录 `ZCODE_CHANNEL=cli|desktop|standalone` 和对应的
资产 URL/SHA。`install/install-zcode-loongarch.sh` 可以安装：

- `cli`：CLI 分发包，写 `/usr/local/bin/zcode-<version>`（默认不覆盖
  `/usr/local/bin/zcode`，`ZCODE_LINK_DEFAULT=1` 才覆盖）；
- `desktop`：捆绑 CLI 的 Tauri 2 deb，需要系统 Node.js >= 24；
- `standalone`：自带 Node 24 + CLI 的 Tauri 2 deb。

linux-loong64 的 ZCode CLI 现在自带 native opentui 渲染器，并捆绑 koffi /
unsafe-pointer 的 loong64 构建；默认入口启动 TUI，`zcode --web` 仍可用。
构建流程在 `loongarch-agent-builds` 的 `build-opentui`（x86_64 交叉编译
`libopentui.so`）和 `build-cli`（loong64 构建 koffi/unsafe-pointer）job 中。

## 自动对齐流程

1. 每日 02:17 UTC（或手动）运行 `agent-version-watch.yml`。
2. `check-agent-versions.sh` 计算每个工具的 selected，与 `versions.env`
   比较。
3. 有差异：更新 `versions.env`、installer 的 `BEGIN/END VERSION FALLBACKS`
   块、README 的 `agent-versions` 块；先跑一致性检查；推送到
   `auto/version-alignment` 分支并创建/更新 PR（PR 正文含变更表）。
4. 无差异：只创建/更新 `agent-update` issue，不建 PR。
5. workflow 不直接提交 `main`、不合并、不安装、不发布。

环境变量（`CODEX_VERSION` 等）仍然可以覆盖清单，仅影响单次安装调用，不会
改动仓库文件。

## 自动 PR 的 CI 与推送前校验

自动对齐分支在推送前，watch job 会在 runner 上执行：

```sh
bash .github/scripts/check-versions-consistency.sh
shellcheck -s sh install/install-loongarch-agents.sh
cd ccswitch-lite && go test ./... && \
  CGO_ENABLED=0 GOOS=linux GOARCH=loong64 go build -trimpath \
  -ldflags "-s -w" -o /tmp/ccswitch-lite .
```

任何一步失败都不会推送分支或创建 PR，所以分支内容本身始终是已验证的。

默认用 `GITHUB_TOKEN` 创建 PR 时，PR 作者是 `github-actions[bot]`，GitHub 会把
该 PR 的 `pull_request` workflow 置为 `action_required`：run 会出现，但没有
任何 job，日志也不可得，需要维护者点击 Approve 后才会运行。**这不是分支内容
错误**；如果在批准前关闭 PR，这个 pending run 还可能变成 `failure`（仍然
0 个 job）。

可选配置仓库 secret `AUTO_ALIGN_TOKEN`（一个 PAT，需具备 contents 与
pull requests 写权限，并能读取私有 builds 仓库）。配置后 workflow 会用该
PAT 读取 draft release、推送分支和创建/更新 PR，PR 作者是 PAT 所属用户，
CI 会自动启动，不再需要每次批准。token 只通过环境变量传给 git/gh，不会写进
仓库；不要把它提交到任何文件。

