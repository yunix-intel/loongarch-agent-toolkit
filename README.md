# LoongArch Agent Toolkit

Practical tools for running AI coding agents on **LoongArch (loongarch64)**
Linux, built and verified on Loongnix 6.6.52 with ABI2.0 userspace.

This repository collects four pieces of work:

| Component | What it is | Status |
| --- | --- | --- |
| [`ccswitch-lite/`](ccswitch-lite/) | Single-binary Go CLI + Web UI for switching Claude Desktop / Claude Code / Codex between private gateways | Working; 78 acceptance assertions pass |
| [`zcode-tauri/`](zcode-tauri/) | Lightweight Tauri 2 shell around the ZCode Web UI | Working; release binary and `.deb` built |
| [`install/`](install/) | Installer for ABI2.0 Node, `codex`, `opencode`, `dsh`, plus optional ZCode CLI/desktop assets | Working; all three CLIs verified; ZCode installer added |
| [`claude-desktop-repack/`](claude-desktop-repack/) | Scripts used for an unofficial Claude Desktop loong64 repack | Experimental; UI/login works, bundled Claude Code is x86-64 |

The official [`farion1231/cc-switch`](https://github.com/farion1231/cc-switch)
Tauri app **has been built for loongarch64**: upstream v4.0.15 compiles with
Rust 1.97.1 and its full UI has been verified under Xvfb. The port lives in the
private repository
[`yunix-intel/cc-switch-loongarch`](https://github.com/yunix-intel/cc-switch-loongarch);
build details are in
[`docs/cc-switch-loongarch.md`](docs/cc-switch-loongarch.md). `ccswitch-lite`
remains a lighter single-binary alternative.

![ccswitch-lite driving Claude Desktop 3P mode](docs/screenshots/ccswitch-3p-gateway.png)

## Repository layout

```text
ccswitch-lite/          Go source, embedded Web UI, tests/
zcode-tauri/            Tauri 2 source, frontend loading page, packaging
install/                Agent installer + reference wrappers
claude-desktop-repack/  Repack scripts and Debian metadata (no app payload)
docs/                   ABI/Node, cc-switch port, Tauri, screenshots
.github/workflows/      ccswitch-lite build + shellcheck CI, agent version watch
```

## Prerequisites

- LoongArch Linux, ABI2.0 userspace (`e_flags 0x43`). Check with
  `LC_ALL=C readelf -h /bin/ls | grep Flags`.
- Go 1.24+ for `ccswitch-lite`.
- Rust 1.85+, GTK 3 and WebKitGTK 4.1 development packages for `zcode-tauri`.
- Root access for the installer (it writes `/opt` and `/usr/local/bin`).
- `curl`, `xz`, `python3` (3.11+ for the acceptance test), `bash`.

## ccswitch-lite

A stdlib-only Go program that manages gateway profiles and writes:

1. Claude Desktop 3P config (`~/.config/Claude*` + `configLibrary`);
2. Claude Code `~/.claude/settings.json` env keys;
3. Codex `~/.codex/config.toml` and `auth.json`.

Build and run:

```sh
cd ccswitch-lite
CGO_ENABLED=0 GOOS=linux GOARCH=loong64 \
  go build -trimpath -ldflags "-s -w" -o ccswitch-lite .
./ccswitch-lite add --name gw --base-url https://api.example.com \
  --api-key sk-xxxx --format anthropic
./ccswitch-lite use gw
./ccswitch-lite list
./ccswitch-lite restore
./ccswitch-lite web            # http://127.0.0.1:18081/
```

`baseUrl` must **not** include `/v1`: Claude Desktop appends `/v1/messages`.
API keys are stored in a 0600 `providers.json`, shown only masked, and the Web
UI refuses non-loopback bind addresses.

Acceptance test (throwaway `HOME`, never touches real configs):

```sh
cd ccswitch-lite
bash tests/test.sh
```

Tests use `python3` with `tomllib`, plus `curl` and `sha256sum`. See
[`ccswitch-lite/README.md`](ccswitch-lite/README.md) for the full config
schema and restore semantics.

## zcode-tauri

Tauri 2 shell that starts `zcode --web --no-open`, parses the loopback URL from
stdout, and shows it in a WebKitGTK window. It stops only the process group it
created.

```sh
cd zcode-tauri
python3 packaging/gen_icons.py                 # if icons are missing
cargo build --release --manifest-path src-tauri/Cargo.toml
sh packaging/build-deb.sh                      # optional .deb/.tar.gz
```

Runtime environment variables: `ZCODE_BIN`, `ZCODE_WEB_URL`,
`ZCODE_TAURI_LOG`, and `ZCODE_TAURI_SOFTWARE_GL=1` (Mesa llvmpipe under Xvfb).
See [`docs/tauri-loongarch.md`](docs/tauri-loongarch.md).

![zcode-tauri running](docs/screenshots/zcode-tauri.png)

## Installing codex / opencode / dsh

```sh
sudo ./install/install-loongarch-agents.sh
```

The installer:

- detects ABI from ELF `e_flags` (`0x3` = ABI1.0, `0x43` = ABI2.0);
- downloads Node **22.23.3** from `loong64/node` (not the ABI1.0 Loongnix FTP
  22.16 tarball) into `/opt/node22-abi2`;
- installs `opencode-ai` and `@deepseek-ai/dsh` at the versions in
  [`install/versions.env`](install/versions.env) from
  `https://registry.loongnix.cn:5873`;
- installs Codex from either the npm channel (`@openai/codex`) or a local
  source-build tarball, selected by `CODEX_CHANNEL`;
- writes `/usr/local/bin/{codex,dsh,opencode}` wrappers (the source channel
  writes `codex-<version>` unless `CODEX_LINK_DEFAULT=1`).

[`install/versions.env`](install/versions.env) is the **single source of
truth** for every pinned version. The installer reads it at runtime, and the
README table below is generated/checked against it (CI fails on drift).
Environment variables (`NODE_VERSION`, `CODEX_VERSION`, `OPENCODE_VERSION`,
`DSH_VERSION`, `VERSIONS_FILE`) still override the manifest; `NODE_PREFIX`
overrides the install prefix. The system Node is untouched.

<!-- agent-versions:begin -->
| 工具 | selected | 说明 |
| --- | --- | --- |
| Node.js | `22.23.3` | ABI2.0 运行时，来自 `loong64/node` |
| Codex | `0.162.0` | 龙芯 loong64 可用最新版（非上游 latest） |
| Codex (source) | `0.163.0` | 私有 builds 仓库的 LoongArch 源码构建（可选通道） |
| OpenCode | `1.19.0` | `opencode-linux-loong64` 最新版 |
| DSH | `0.2.1-rc.2` | Loongnix registry 最新版 |
| Claude Code | `2.1.112` | 最后一个 npm tarball 仍带 `cli.js` 的版本 |
| ZCode | `v3.15.1` | `zai-org/ZCode` 最新 semver tag（非 GitHub release） |
| cc-switch | `v4.0.17` | `farion1231/cc-switch` 最新 release |
<!-- agent-versions:end -->

`selected` 的含义是“当前龙芯上可用的最新版”，不一定是上游 latest。版本
选择规则、Claude Code native-only 的处理和 ZCode 为什么跟 tag 而不是
release，见 [`docs/version-policy.md`](docs/version-policy.md)。

### Codex: npm vs source

`CODEX_CHANNEL=npm`（默认）安装 Loongnix registry 的
`@openai/codex@CODEX_VERSION` 并写默认 `codex`。`CODEX_CHANNEL=source` 则把
源码构建包解到 `/opt/codex-<CODEX_SOURCE_VERSION>`，写
`/usr/local/bin/codex-<version>`；除非 `CODEX_LINK_DEFAULT=1`，**不会覆盖**
默认 `codex`。

```sh
sudo CODEX_CHANNEL=source \
  CODEX_SOURCE_URL=/path/to/codex-rust-v0.163.0-loongarch64.tar.gz \
  CODEX_SOURCE_SHA256=acfeda1d8c6e98fee9d9935d97f94ed1ff9901236bb2cde7d7ffa517397a896d \
  ./install/install-loongarch-agents.sh
```

`CODEX_SOURCE_URL` 支持 `http(s)://` 或本地 `.tar.gz`。私有 GitHub release
资产需 `CODEX_SOURCE_TOKEN`（或 `GITHUB_TOKEN`）；安装器在解包前校验
SHA-256，并拒绝包含绝对路径或 `..` 的条目。

### ZCode CLI / desktop

ZCode 的 CLI 与两个 Tauri 桌面 deb 在私有
`yunix-intel/loongarch-agent-builds` 的 release 中。`install-zcode-loongarch.sh`
支持三种通道：

```sh
# CLI（需要系统 Node.js >= 24；默认只写 zcode-<version>，不覆盖默认 zcode）
sudo ZCODE_CHANNEL=cli \
  ZCODE_CLI_URL=https://api.github.com/repos/yunix-intel/loongarch-agent-builds/releases/assets/<id> \
  ZCODE_CLI_SHA256=<64-hex> \
  ZCODE_SOURCE_TOKEN=<private-asset-token> \
  ./install/install-zcode-loongarch.sh

# 轻量 Tauri 桌面（捆绑 CLI，依赖系统 Node >= 24）
sudo ZCODE_CHANNEL=desktop ZCODE_DESKTOP_DEB_URL=... ZCODE_DESKTOP_DEB_SHA256=... \
  ZCODE_SOURCE_TOKEN=... ./install/install-zcode-loongarch.sh

# 自带 Node + CLI 的桌面版
sudo ZCODE_CHANNEL=standalone ZCODE_STANDALONE_DEB_URL=... ZCODE_STANDALONE_DEB_SHA256=... \
  ZCODE_SOURCE_TOKEN=... ./install/install-zcode-loongarch.sh
```

资产 URL/SHA 也可以写进 `install/versions.env` 的 `ZCODE_*` 字段。loong64
没有 `@mbears/opentui-core-linux-loong64`，所以 CLI 默认入口启动 Web UI；
`zcode tui` 会明确报错。Web 和 Tauri 桌面不受影响。

Why ABI matters, and why Node 22.16 silently does nothing for `dsh`, is
documented in [`docs/abi-and-node.md`](docs/abi-and-node.md).

## Agent version watch and alignment

[`.github/workflows/agent-version-watch.yml`](.github/workflows/agent-version-watch.yml)
runs daily at 02:17 UTC (and on demand) on GitHub-hosted `ubuntu-latest`, so it
needs no loong64 runner. It reads `install/versions.env`, queries:

- upstream npm `latest` for Codex, OpenCode, DSH and Claude Code;
- Loongnix `loong64` builds (`@openai/codex` `-linux-loong64` versions,
  `opencode-linux-loong64`, `@deepseek-ai/dsh`);
- the Claude Code npm tarball for the newest version that still contains
  `cli.js` (2.1.113+ are native-only);
- `zai-org/ZCode` tags **and** releases (tags are authoritative);
- `farion1231/cc-switch` latest release;
- source-built Codex releases (including drafts) in the private
  `yunix-intel/loongarch-agent-builds` repository when `AUTO_ALIGN_TOKEN` can
  read it; a newer build updates `CODEX_SOURCE_VERSION/URL/SHA256`, while
  `CODEX_CHANNEL` stays `npm` unless changed by hand. Without the token the
  issue reports `source build available (private; set AUTO_ALIGN_TOKEN or URL)`
  and the npm pin is not touched.

It then writes a table with `upstream / loong64 可用 / selected / 状态` and
creates or updates the single open issue labeled
[`agent-update`](https://github.com/yunix-intel/loongarch-agent-toolkit/issues?q=label%3Aagent-update).

**Automatic alignment:** when `selected` differs from `install/versions.env`,
the workflow updates the manifest, the installer fallback block and the README
table, pushes to the `auto/version-alignment` branch and opens (or updates a)
pull request whose body lists every change. It never commits to `main`, never
merges, never installs and never publishes. When nothing is selectable it only
updates the issue and opens no PR. Statuses such as
`waiting-for-loong64-port` mean upstream is ahead but no loong64 build exists
yet.

CI also runs `.github/scripts/check-versions-consistency.sh`, which fails if
`versions.env`, the installer fallbacks and the README table disagree.

Trigger it manually and inspect the result:

```sh
gh workflow run agent-version-watch.yml
gh run list --workflow=agent-version-watch.yml --limit 1
gh run view <run-id> --log        # or: gh run view <run-id> --web
```

The step summary (table + status) is on the run page; actionable results are
tracked in the `agent-update` issue, and proposed bumps in the auto-alignment
PR. The branch is validated **before** it is pushed (manifest consistency,
`shellcheck`, `go test` and a loong64 build), so its content does not depend on
extra CI runs.

A PR opened with the default `GITHUB_TOKEN` is authored by
`github-actions[bot]`; GitHub parks its `pull_request` run in
`action_required` (no jobs, no logs) until a maintainer approves, which is not
a content failure. Optionally set a repository secret `AUTO_ALIGN_TOKEN` (a PAT
with contents and pull-request write access) so the branch and PR are created
as that user and CI starts automatically; the token is passed only through the
environment and is never committed. See
[`docs/version-policy.md`](docs/version-policy.md#自动-pr-的-ci-与推送前校验).

## Claude Desktop repack

`claude-desktop-repack/` contains only our glue: an ASAR extractor, a JS
replacement for `@ant/claude-native`, an AppRun, a desktop entry and Debian
metadata. It contains **no** official `app.asar`, Electron binary or Anthropic
payload. The repack can display the UI and honour the 3P gateway profile, but
Code/Cowork sessions fail because the bundled Claude Code binary is x86-64.
Not affiliated with Anthropic.

## Known limitations

- `ccswitch-lite` keeps API keys in plaintext (0600 file), not a keyring.
- Custom headers are written only for Codex; Desktop/Claude Code have no
  corresponding config slot.
- The Web UI has no authentication and is loopback-only by design.
- The official cc-switch loong64 port is built from upstream source and ships a
  `.deb`; see
  [`docs/cc-switch-loongarch.md`](docs/cc-switch-loongarch.md). `ccswitch-lite`
  remains the smaller, stdlib-only option.
- Claude Desktop's bundled Claude Code is x86-64, so Code/Cowork cannot run on
  LoongArch.

## Security

This repository intentionally excludes binaries, logs, cookies, package
caches, SSH material and API keys. Example keys in documentation are
placeholders. Do not commit `~/.claude`, `~/.codex`, `providers.json`,
`cookies.txt` or Anthropic application payloads.

## License

Our code is MIT-licensed; see [`LICENSE`](LICENSE). Third-party components
remain under their own licenses; see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
