# LoongArch Agent Toolkit

Practical tools for running AI coding agents on **LoongArch (loongarch64)**
Linux, built and verified on Loongnix 6.6.52 with ABI2.0 userspace.

This repository collects four pieces of work:

| Component | What it is | Status |
| --- | --- | --- |
| [`ccswitch-lite/`](ccswitch-lite/) | Single-binary Go CLI + Web UI for switching Claude Desktop / Claude Code / Codex between private gateways | Working; 78 acceptance assertions pass |
| [`zcode-tauri/`](zcode-tauri/) | Lightweight Tauri 2 shell around the ZCode Web UI | Working; release binary and `.deb` built |
| [`install/`](install/) | Installer for ABI2.0 Node, `codex`, `opencode`, `dsh` from the Loongnix registry | Working; all three CLIs verified |
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
- installs `@openai/codex@0.162.0`, `opencode-ai@1.17.11` and the latest
  `@deepseek-ai/dsh` from `https://registry.loongnix.cn:5873`;
- writes `/usr/local/bin/{codex,dsh,opencode}` wrappers.

Override versions with `NODE_VERSION`, `CODEX_VERSION`, `OPENCODE_VERSION`,
`DSH_VERSION`, or the prefix with `NODE_PREFIX`. The system Node is untouched.

Why ABI matters, and why Node 22.16 silently does nothing for `dsh`, is
documented in [`docs/abi-and-node.md`](docs/abi-and-node.md).

## Agent version watch

[`.github/workflows/agent-version-watch.yml`](.github/workflows/agent-version-watch.yml)
runs daily at 02:17 UTC (and on demand) on GitHub-hosted `ubuntu-latest`, so it
needs no loong64 runner. It compares the pins in
`install/install-loongarch-agents.sh` with the upstream npm registry and with
the Loongnix registry (`https://registry.loongnix.cn:5873`), taking loong64
builds only (`@openai/codex` versions ending in `-linux-loong64`,
`opencode-linux-loong64`, and `@deepseek-ai/dsh`), and reports:

| 工具 | 已 pin | 上游 latest | loong64 可用 latest | 状态 |
| --- | --- | --- | --- | --- |

Status is `可升级`, `等待移植`, `已最新` or `需人工确认`. When anything is
actionable the workflow creates or updates the single open issue labeled
[`agent-update`](https://github.com/yunix-intel/loongarch-agent-toolkit/issues?q=label%3Aagent-update),
mentioning `@yunix-intel` with the table and the exact `CODEX_VERSION=...`
`OPENCODE_VERSION=...` / `DSH_VERSION=...` install command. When everything is
current it only writes the job step summary and opens no issue. The workflow
never edits the pins and never installs anything.

Trigger it manually and inspect the result:

```sh
gh workflow run agent-version-watch.yml
gh run list --workflow=agent-version-watch.yml --limit 1
gh run view <run-id> --log        # or: gh run view <run-id> --web
```

The step summary (table + status) is on the run page; actionable results are
tracked in the `agent-update` issue, not in the run log.

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
