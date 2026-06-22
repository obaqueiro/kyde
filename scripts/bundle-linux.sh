#!/usr/bin/env bash
# Wrap the release binary in an AppImage — a single portable, double-clickable
# file with the Kyde icon + a .desktop launcher. Mirrors bundle-macos.sh.
#
#   ./scripts/bundle-linux.sh            # builds release, emits dist/Kyde-x86_64.AppImage
#
# Note: this does NOT bundle gpui's system libraries (Vulkan/Wayland/X11/
# fontconfig). The target machine needs those installed — same runtime deps as
# building from source. Full lib bundling for a GPU app is fragile and deferred.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BIN="target/release/kyde"
if [[ ! -x "$BIN" ]]; then
  echo "building release binary…"
  cargo build --release
fi

APPDIR="dist/Kyde.AppDir"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

cp "$BIN" "$APPDIR/usr/bin/kyde"

# Icon: committed PNG (assets/AppIcon.png). AppImage wants it both at the AppDir
# root (named after the desktop entry) and under the hicolor theme path.
cp assets/AppIcon.png "$APPDIR/usr/share/icons/hicolor/256x256/apps/kyde.png"
cp assets/AppIcon.png "$APPDIR/kyde.png"

cat > "$APPDIR/kyde.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Kyde
GenericName=Git commit & diff tool
Exec=kyde
Icon=kyde
Categories=Development;RevisionControl;
Terminal=false
EOF
cp "$APPDIR/kyde.desktop" "$APPDIR/usr/share/applications/kyde.desktop"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/kyde" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# appimagetool — download the continuous release if not already present.
TOOL="${APPIMAGETOOL:-}"
if [[ -z "$TOOL" ]]; then
  TOOL="dist/appimagetool"
  if [[ ! -x "$TOOL" ]]; then
    echo "downloading appimagetool…"
    curl -fsSL -o "$TOOL" \
      "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
    chmod +x "$TOOL"
  fi
fi

# Extract-and-run avoids needing FUSE (GitHub runners don't have it).
export APPIMAGE_EXTRACT_AND_RUN=1
ARCH=x86_64 "$TOOL" "$APPDIR" "dist/Kyde-x86_64.AppImage"
echo "built dist/Kyde-x86_64.AppImage"
