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
| Codex | Loongnix registry 中最新的 `@openai/codex-<ver>-linux-loong64`；若私有 builds 仓库有更高的源码构建 release，则取较高者（best-effort） | `waiting-for-loong64-port` |
| OpenCode | `opencode-linux-loong64` 的 `latest` | `waiting-for-loong64-port` |
| DSH | Loongnix registry 的 `@deepseek-ai/dsh@latest` | `waiting-upstream-sync` |
| Claude Code | npm 上**最后一个仍包含 `cli.js`** 的版本 | `native-only` |
| ZCode | `zai-org/ZCode` 的最新 semver tag | `tag-ahead-of-release` |
| cc-switch | `farion1231/cc-switch` 的最新 GitHub release | `up-to-date` |

只有当 Loongnix（或源码构建）真的产出了 loong64 版本，workflow 才会把
selected 往上调。上游发了新版但没有 loong64 构建时，issue 会标注
`waiting-for-loong64-port`，不会产生 PR。

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
