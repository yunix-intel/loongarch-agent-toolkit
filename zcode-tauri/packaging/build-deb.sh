#!/bin/sh
# Build a loong64 .deb and .tar.gz for the Tauri shell.
# Run after: cargo build --release --manifest-path src-tauri/Cargo.toml
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
VERSION=${VERSION:-3.15.1-1}

PKG=$ROOT/pkg/zcode-tauri
BIN=$ROOT/src-tauri/target/release/zcode-tauri
FRONTEND=$ROOT/frontend/index.html

[ -x "$BIN" ] || {
    echo "missing $BIN; run: cargo build --release --manifest-path src-tauri/Cargo.toml" >&2
    exit 1
}
[ -f "$FRONTEND" ] || {
    echo "missing $FRONTEND" >&2
    exit 1
}

rm -rf "$PKG"
mkdir -p "$PKG/DEBIAN" \
         "$PKG/opt/zcode-tauri/dist" \
         "$PKG/usr/lib/zcode-tauri" \
         "$PKG/usr/bin" \
         "$PKG/usr/share/applications" \
         "$PKG/usr/share/icons/hicolor/scalable/apps" \
         "$PKG/usr/share/icons/hicolor/128x128/apps" \
         "$PKG/usr/share/doc/zcode-tauri"

install -m 0755 "$BIN" "$PKG/usr/lib/zcode-tauri/zcode-tauri"
install -m 0644 "$FRONTEND" "$PKG/opt/zcode-tauri/dist/index.html"
install -m 0755 "$ROOT/packaging/zcode-tauri.launcher" "$PKG/usr/bin/zcode-tauri"
install -m 0644 "$ROOT/packaging/zcode-tauri.desktop" "$PKG/usr/share/applications/zcode-tauri.desktop"
install -m 0644 "$ROOT/icons/zcode-tauri.svg" "$PKG/usr/share/icons/hicolor/scalable/apps/zcode-tauri.svg"
install -m 0644 "$ROOT/src-tauri/icons/128x128.png" "$PKG/usr/share/icons/hicolor/128x128/apps/zcode-tauri.png"
install -m 0644 "$ROOT/packaging/README.package" "$PKG/usr/share/doc/zcode-tauri/README"

SIZE=$(du -sk "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<EOF
Package: zcode-tauri
Version: $VERSION
Architecture: loong64
Maintainer: yunix <yunix@localhost>
Installed-Size: $SIZE
Depends: libc6 (>= 2.41), libgtk-3-0, libwebkit2gtk-4.1-0, libsoup-3.0-0
Section: utils
Priority: optional
Homepage: https://z.ai
Description: Lightweight Tauri 2 desktop shell for the ZCode Web UI
 Wraps the local zcode --web --no-open server in a native WebKitGTK
 window.  The shell starts the backend, waits for its dynamically
 allocated loopback port, and stops only the process group it created
 when the window closes.  It does not bundle an Electron runtime.
EOF

mkdir -p "$ROOT/dist"
dpkg-deb --build --root-owner-group "$PKG" "$ROOT/dist/zcode-tauri_${VERSION}_loong64.deb"

(
    cd "$ROOT/pkg"
    tar -czf "$ROOT/dist/zcode-tauri_${VERSION}_loong64.tar.gz" zcode-tauri
)

ls -lh "$ROOT/dist"/zcode-tauri_"${VERSION}"_loong64.*
dpkg-deb -f "$ROOT/dist/zcode-tauri_${VERSION}_loong64.deb" Package Version Architecture Installed-Size Depends
