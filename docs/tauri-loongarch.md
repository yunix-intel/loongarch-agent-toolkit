# Tauri 2 on LoongArch notes

This repository's `zcode-tauri` is our own small Tauri 2 shell around the ZCode
Web UI. It builds cleanly on loong64 with Rust 1.85. The official cc-switch is a
separate project; its loong64 build uses Rust 1.97.1 and is documented in
[`docs/cc-switch-loongarch.md`](cc-switch-loongarch.md).

## Toolchain that worked

| Component | Version |
| --- | --- |
| rustc / cargo | 1.85.0 (Loongnix source tarball) |
| tauri | 2.8.2 (pinned) |
| tauri-build | 2.4.0 (pinned) |
| WebKitGTK | 4.1 (`libwebkit2gtk-4.1-dev`, `libsoup-3.0-dev`) |
| GTK | 3 |

`Cargo.toml` pins the Tauri crates and `.cargo/config.toml` contains:

```toml
[resolver]
incompatible-rust-versions = "fallback"
```

Without the fallback, Cargo 1.85 refuses to resolve because newer versions of
`icu_*`, `serde_with`, `tauri-runtime` and others require Rust 1.88/1.90.
`Cargo.lock` is committed so builds are reproducible with a 1.85 toolchain.

`tauri-build` requires `src-tauri/icons/icon.png` at compile time. Run
`python3 packaging/gen_icons.py` if the icons are missing; the generator writes
32/128/256 px PNGs into `src-tauri/icons/`.

## Build

```sh
cd zcode-tauri
cargo build --release --manifest-path src-tauri/Cargo.toml
# optional .deb + tarball
sh packaging/build-deb.sh
```

`src-tauri/tauri.conf.json` points `frontendDist` at `../frontend`, so the
loading page is a tracked source file rather than a generated `dist/` directory.

## Runtime behaviour

- Spawns `zcode --web --no-open` (override with `ZCODE_BIN`).
- Parses the first loopback `http://127.0.0.1:<port>/` URL from stdout and waits
  up to 30 seconds for the TCP port.
- Creates a 1200x800 WebKitGTK window.
- The backend runs in its own process group; closing the window sends SIGTERM
  to that group, then SIGKILL after 5 seconds. A user-started `zcode` is not
  touched.
- `ZCODE_WEB_URL` attaches to an already-running Web UI instead.
- `ZCODE_TAURI_SOFTWARE_GL=1` forces Mesa llvmpipe. This is needed under Xvfb:
  the Loongnix EGL vendor libraries (loonggpu/gsgpu) cannot create a software
  EGL display there.

The launcher also prepends `/opt/node24/bin` to `PATH`, because ZCode itself
uses Node 24.

## ring on loongarch64

Earlier revisions of this note claimed that `ring` blocked the official
cc-switch port. That was wrong:

- `ring 0.17.14` compiles on loongarch64 with Rust 1.97.1;
- the `panic!("unsupported arch")` branch in `ring`'s `build.rs` belongs to the
  Windows x86 NASM path and is not taken by the Linux loong64 build;
- official cc-switch builds with
  `cargo build --release --locked --features tauri/custom-protocol`.
  `custom-protocol` is mandatory: without it the webview keeps pointing at the
  `devUrl` (`localhost:3000`) instead of the bundled frontend.

The port, its self-hosted runner and the `.deb` packaging are described in
[`docs/cc-switch-loongarch.md`](cc-switch-loongarch.md).

`zcode-tauri` itself has no `ring` dependency:

```sh
cargo tree -i ring
# error: package ID specification `ring` did not match any packages
```

## Packaging

`packaging/build-deb.sh` builds `zcode-tauri_<version>_loong64.deb` and a
`.tar.gz`. It installs:

- `/usr/lib/zcode-tauri/zcode-tauri`
- `/opt/zcode-tauri/dist/index.html`
- `/usr/bin/zcode-tauri`
- desktop entry and icons

`packaging/send_wm_delete.c` is an optional helper for window-manager testing:

```sh
cc packaging/send_wm_delete.c -o send_wm_delete -lX11
```
