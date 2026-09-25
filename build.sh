#!/bin/bash
# Builds Scribe.app from main.swift. Requires Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP="Scribe.app"
BIN="Scribe"
BUNDLE_ID="com.ethantruslow.scribe"
VERSION="1.0"
# Signing identity. "Scribe Dev" if you ever run make-cert.sh, otherwise the
# "CursorGlow Dev" certificate that is already trusted on this machine — one
# self-signed root is enough for both apps, and reusing it saves an extra
# keychain-trust password prompt. Either one is stable across rebuilds, which
# is the only property that matters here.
SIGN_ID=""
for candidate in "Scribe Dev" "CursorGlow Dev"; do
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$candidate"; then
    SIGN_ID="$candidate"
    break
  fi
done

if ! command -v swiftc >/dev/null 2>&1; then
  cat <<'MSG'
Swift compiler (swiftc) not found.

Install the Xcode Command Line Tools, then run this script again:

    xcode-select --install
MSG
  exit 1
fi

# A running copy holds the old binary open.
if pgrep -x "$BIN" >/dev/null 2>&1; then
  echo "Quitting the running copy..."
  killall "$BIN" 2>/dev/null || true
  sleep 1
fi

echo "Compiling..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Theme artwork. ExportTheme.logo looks these up by name in Resources, and
# degrades to a logo-less header if one is missing rather than failing an
# export — so a missing file here is silent. Check the copy if a logo vanishes.
# Theme logos only. icon-*.png is icon source art, not a theme asset — it is
# 400 KB that would otherwise ride along in every build for nothing.
if [ -d assets ]; then
  for LOGO in assets/*.png; do
    case "$(basename "$LOGO")" in
      icon-*) continue ;;
    esac
    cp -f "$LOGO" "$APP/Contents/Resources/" 2>/dev/null || true
  done
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Scribe</string>
    <key>CFBundleDisplayName</key>       <string>Scribe</string>
    <key>CFBundleExecutable</key>        <string>${BIN}</string>
    <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key>           <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>CFBundleIconFile</key>          <string>Scribe</string>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

# ── App icon ─────────────────────────────────────────────────────────────────
#
# Built from the single assets/icon-1024.png. Scribe is LSUIElement so there is
# usually no Dock icon at all — but the editor flips the activation policy to
# .regular, so the icon shows in the Dock for as long as that window is open,
# and in the Finder always.
#
# Regenerate the source art with:
#     swift assets/make-icon.swift mark      (annotated-screenshot mark)
#     swift assets/make-icon.swift badger    (school logo on a light tile)
if [ -f assets/icon-1024.png ]; then
  ICONSET="$(mktemp -d)/Scribe.iconset"
  mkdir -p "$ICONSET"
  for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" assets/icon-1024.png \
      --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null 2>&1
    sips -z "$((SIZE * 2))" "$((SIZE * 2))" assets/icon-1024.png \
      --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Scribe.icns" 2>/dev/null; then
    echo "Icon built from assets/icon-1024.png"
  else
    echo "!! iconutil failed — the app will use the generic icon."
  fi
  rm -rf "$(dirname "$ICONSET")"
else
  echo "!! assets/icon-1024.png missing — generic icon. Run:"
  echo "!!     swift assets/make-icon.swift mark"
fi

swiftc -O \
  -framework Cocoa \
  -framework Carbon \
  -framework ScreenCaptureKit \
  -framework VideoToolbox \
  -framework ImageIO \
  -o "$APP/Contents/MacOS/$BIN" \
  main.swift

# ── Signing ──────────────────────────────────────────────────────────────────
#
# This is the part that decides whether Screen Recording and Accessibility
# survive a rebuild.
#
# Ad-hoc signing (`--sign -`) pins the app's identity to the SHA of the binary,
# so every rebuild is a different app as far as macOS is concerned. TCC keeps
# showing the switch as ON while silently refusing access, because the grant it
# stored points at a build that no longer exists.
#
# A self-signed certificate pins identity to the certificate, which never
# changes — so one grant lasts forever.

if [ -n "$SIGN_ID" ]; then
    codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1
    echo
    echo "Signed with the stable '$SIGN_ID' identity."
    echo "Permissions will survive future rebuilds."
    STABLE=yes
else
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1 || true
    echo
    echo "!! Signed ad-hoc — permissions will BREAK on every rebuild."
    echo "!! Create the one-time certificate first:"
    echo "!!"
    echo "!!     bash make-cert.sh"
    echo "!!"
    echo "!! then run this script again."
    STABLE=no
fi

echo
echo "Built $(pwd)/$APP  (v${VERSION})"
echo "Run it:  open '$APP'"

if [ "$STABLE" = yes ]; then
  echo
  echo "Switching signing identity invalidates the old grants ONE time."
  echo "If capture or element names still refuse, clear and re-grant once:"
  echo
  echo "    tccutil reset ScreenCapture ${BUNDLE_ID}"
  echo "    tccutil reset Accessibility ${BUNDLE_ID}"
fi
