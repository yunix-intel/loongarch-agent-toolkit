# Official cc-switch on LoongArch

The official [`farion1231/cc-switch`](https://github.com/farion1231/cc-switch)
Tauri application now builds and runs on loongarch64. The port is maintained in
the private repository
[`yunix-intel/cc-switch-loongarch`](https://github.com/yunix-intel/cc-switch-loongarch).

Status: upstream **v4.0.18** built natively on LoongArch. The complete UI was
verified under Xvfb, including the Claude Code, Claude Desktop, Codex, Gemini,
OpenCode, MCP, Skills and Prompts pages.

## Earlier claim

An earlier version of this toolkit said cc-switch could not be ported because
`ring` has no loongarch64 backend. That conclusion was wrong:

- `ring 0.17.14` compiles for loongarch64 with Rust 1.97.1.
- The `panic!("unsupported arch")` in `ring`'s `build.rs` is on the Windows x86
  `nasm()` path. The Linux loong64 build does not take it.
- No crypto-provider replacement or `rustls-rustcrypto` rewrite is needed.

## Toolchain

| Component | Value |
| --- | --- |
| rustc / cargo | 1.97.1 (`/opt/rust-1.97/env.sh`) |
| Node.js | 24 (`/opt/node24`) |
| pnpm | via `corepack`, using upstream's `packageManager` field |
| WebKitGTK | 4.1 |
| GTK | 3 |

The upstream repository's `rust-toolchain.toml` pins an older channel, but the
loong64 build sources `/opt/rust-1.97/env.sh` first, which supplies
`rustc 1.97.1` and the matching `LD_LIBRARY_PATH`.

## Build

From the upstream tag (unmodified source):

```sh
# frontend
corepack enable
COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack prepare "$(node -p "require('./package.json').packageManager")" --activate
pnpm install --frozen-lockfile --registry=https://registry.loongnix.cn:5873
pnpm run build:renderer

# backend
. /opt/rust-1.97/env.sh
cd src-tauri
cargo build --release --locked --features tauri/custom-protocol
```

The `tauri/custom-protocol` feature is **required**. Without it the release
binary keeps a `devUrl` pointing at `http://localhost:3000` and shows a blank or
connection-refused window instead of the bundled frontend.

The Loongnix npm mirror republishes a few tarballs with checksums that do not
match upstream's lockfile (observed for `@tauri-apps/cli`, `lightningcss` and
`rollup`). The CI workflow retries a frozen install against
`https://registry.npmjs.org` when the mirror fails integrity validation.

## Xvfb smoke test

```sh
export XDG_RUNTIME_DIR="$RUNNER_TEMP/xdg-runtime"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

setsid timeout --kill-after=5s 45s \
  xvfb-run -a -s "-screen 0 1280x800x24" \
  dbus-run-session -- env \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    LIBGL_ALWAYS_SOFTWARE=1 \
    WEBKIT_DISABLE_COMPOSITING_MODE=1 \
    WEBKIT_DISABLE_DMABUF_RENDERER=1 \
    WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1 \
    src-tauri/target/release/cc-switch
```

The runner passes when the process is still alive after 15 seconds and the log
contains `主窗口已显示` (main window shown). A dedicated `XDG_RUNTIME_DIR` is
needed because the CI account is a system user without `/run/user/<uid>`;
otherwise `libayatana-appindicator` fails with `EACCES`.

## CI / self-hosted runner

The port uses a native LoongArch runner with labels:

```text
[self-hosted, linux, loong64, ccswitch-loongarch]
```

The runner account is the dedicated user `github_ci_runner` (no sudo, no SSH
key). The `Upstream LoongArch Watch` workflow runs every six hours:

1. resolves the latest upstream cc-switch release tag;
2. fetches that tag and checks it out unmodified;
3. installs frontend dependencies and builds the renderer;
4. builds the Rust binary with `tauri/custom-protocol`;
5. runs the Xvfb smoke test;
6. packages a `.deb`;
7. creates a draft release named `loongarch-<upstream-tag>` (published only when
   `AUTO_PUBLISH_RELEASES=true`).

## `.deb` artifact

```text
cc-switch_<upstream-version>~loong64.1_loong64.deb
```

Contents:

- `/usr/bin/cc-switch` — the release binary;
- `/usr/share/applications/cc-switch.desktop` — from `flatpak/com.ccswitch.desktop.desktop`;
- `/usr/share/icons/hicolor/128x128/apps/com.ccswitch.desktop.png`;
- `Depends: libwebkit2gtk-4.1-0, libgtk-3-0`;
- `Architecture: loong64`.

The release also carries a `SHA256SUMS` file. Build artifacts are uploaded to
the release, not committed to this repository.
