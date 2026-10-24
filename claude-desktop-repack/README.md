# claude-desktop-repack (historical scripts)

> **Historical, not the maintained build path.** The maintained Claude Desktop
> loong64 build (including the tested `@ant/claude-native` shim, 41/41 tests,
> fd-relative safe-fs and fail-closed socket) lives in
> [`yunix-intel/claude-desktop-loongarch`](https://github.com/yunix-intel/claude-desktop-loongarch).
> Use that repository for a current package. The packaging files here are kept
> as historical references and are not used by that build.

Unofficial, experimental repack of the **official amd64 Claude Desktop** for
LoongArch. This directory contains only our own shell/Python glue and
packaging metadata.

It deliberately does **not** contain:

- the official `app.asar` or any extracted application code;
- Electron binaries, `node-pty` binaries or `squashfuse` sources;
- any `.deb`, AppImage, squashfs image, screenshot or log;
- Anthropic trademarks/assets beyond the package metadata needed to describe
  the repack.

Nothing here is affiliated with or endorsed by Anthropic.

## Why a repack is needed

Anthropic does not publish a loong64 build. The practical route is:

1. take the official amd64 `.deb` application payload (`app.asar`);
2. provide a loong64 Electron runtime (community `electron-loong64` build);
3. replace the native `@ant/claude-native` addon with the tested JS shim from
   `claude-desktop-loongarch/shim/index.js`;
4. rebuild `node-pty` for loong64;
5. repackage as an AppImage or `.deb`.

The JavaScript application itself is architecture-independent; the blockers are
the Electron runtime and the native Node addons.

## Files

| File | Purpose |
| --- | --- |
| `readasar.py` | Minimal ASAR reader: `python3 readasar.py app.asar path/inside/archive > out`. Used to inspect/extract the official payload. |
| `amotest.c` | One-line LoongArch AMO sanity check. Build: `cc amotest.c -o amotest && ./amotest`; prints `AMO_OK`. |
| `AppRun` | AppImage entry point. Sets `LD_LIBRARY_PATH` and passes `--no-sandbox` when running as root or when user namespaces are disabled. |
| `claude-desktop.desktop` | Desktop entry, including `StartupWMClass=com.anthropic.Claude` so docks group windows correctly. |
| `debian/control`, `debian/postinst`, `debian/prerm` | Debian packaging metadata: chrome-sandbox permissions, desktop/MIME cache updates. |

## Known limitations

- The repacked app starts, shows the UI, and the 3P gateway profile written by
  `ccswitch-lite` is honoured (`3P mode active`, model discovery skipped).
- Code/Cowork sessions download Anthropic's bundled **x86-64** Claude Code
  binary and fail on LoongArch with `Cowork requires a supported CPU
  architecture on Linux`. This is an upstream payload limitation, not a config
  problem.
- Use only with your own licensed copy of Claude Desktop. Do not redistribute
  the repacked application or Anthropic's payload.

## Build outline

```sh
# 1. Inspect/extract the official payload (not committed)
python3 readasar.py /path/to/app.asar package.json
python3 readasar.py /path/to/app.asar .vite/build/index.js > index.js

# 2. Replace @ant/claude-native with the tested shim:
#    https://github.com/yunix-intel/claude-desktop-loongarch/blob/main/shim/index.js
#    (The old minimal shim that lived here was removed: it did not reject
#    ".."/separators or symlinks and could escape the safe-fs root.)

# 3. Rebuild node-pty for loong64 against the Electron headers.

# 4. Rebuild app.asar, then place the tree into a loong64 Electron AppDir.

# 5. Assemble:
#    AppDir/AppRun, AppDir/claude-desktop.desktop, AppDir/claude-desktop.png
#    appimagetool AppDir Claude-<version>-loong64.AppImage
#    or dpkg-deb --build --root-owner-group <pkgdir> claude-desktop_<version>_loong64.deb
```

The exact Electron version used in the original experiment was 43.7.7 and the
official application payload was 2.42304.0. Re-check both versions before
reusing these scripts; internal paths and native-module signatures change.
