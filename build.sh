#!/bin/bash
# Builds SnapMark.app as a universal binary (Apple Silicon + Intel).
#
#   ./build.sh            universal (arm64 + x86_64)
#   ./build.sh --native   current architecture only (faster, for development)
#
# Signing: ad-hoc by default. macOS ties the Screen Recording permission to the code
# signature, so every ad-hoc rebuild needs the permission re-granted. To keep it across
# rebuilds, create a self-signed code-signing certificate once (see README) and run:
#   SNAPMARK_SIGN_IDENTITY="SnapMark Dev" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SnapMark"
DIST="dist"
APP="$DIST/$APP_NAME.app"
NATIVE_ARCH="$(uname -m)"
mkdir -p "$DIST"

# Signing identity: explicit env var, else the stable dev identity from Packaging/make_dev_cert.sh
# if it exists, else ad-hoc.
DEV_KC="$HOME/Library/Keychains/snapmark-dev.keychain-db"
DEV_PASS_FILE="$HOME/Library/Application Support/SnapMark/dev-keychain.pass"
KEYCHAIN_ARGS=()
if [[ -n "${SNAPMARK_SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY="$SNAPMARK_SIGN_IDENTITY"
elif [[ -f "$DEV_KC" ]] && security find-identity -v -p codesigning "$DEV_KC" 2>/dev/null | grep -q '"SnapMark Dev"'; then
  SIGN_IDENTITY="SnapMark Dev"
  KEYCHAIN_ARGS=(--keychain "$DEV_KC")
  if [[ -f "$DEV_PASS_FILE" ]]; then
    security unlock-keychain -p "$(cat "$DEV_PASS_FILE")" "$DEV_KC" 2>/dev/null || true
  fi
else
  SIGN_IDENTITY="-"
fi

# Multi-arch `swift build --arch a --arch b` needs full Xcode; with Command Line Tools we
# build each slice via --triple and merge with lipo.
if [[ "${1:-}" == "--native" ]]; then
  echo "▸ Building (native arch only: $NATIVE_ARCH) ..."
  swift build -c release
  BIN_PATH="$(swift build -c release --show-bin-path)"
  MERGED_BIN="$BIN_PATH/$APP_NAME"
else
  echo "▸ Building x86_64 slice ..."
  swift build -c release --triple x86_64-apple-macosx13.0
  echo "▸ Building arm64 slice ..."
  swift build -c release --triple arm64-apple-macosx13.0
  X86_BIN="$(swift build -c release --triple x86_64-apple-macosx13.0 --show-bin-path)/$APP_NAME"
  ARM_BIN="$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)/$APP_NAME"
  BIN_PATH="$(dirname "$X86_BIN")"
  MERGED_BIN="$DIST/$APP_NAME-universal"
  echo "▸ Merging with lipo ..."
  lipo -create "$X86_BIN" "$ARM_BIN" -output "$MERGED_BIN"
fi

echo "▸ Assembling ${APP} ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$MERGED_BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Localizations go straight into Contents/Resources (standard layout the app looks in).
for lproj in Sources/SnapMark/Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# App icon.
if [[ ! -f "$DIST/AppIcon.icns" ]]; then
  echo "▸ Generating app icon ..."
  swift Packaging/gen_icon.swift "$DIST"
  iconutil -c icns "$DIST/AppIcon.iconset" -o "$DIST/AppIcon.icns"
fi
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "▸ Code signing (ad-hoc) ..."
else
  echo "▸ Code signing with identity: $SIGN_IDENTITY ..."
fi
codesign --force --deep ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict "$APP" && echo "▸ Signature verified"
codesign -d -r- "$APP" 2>&1 | grep designated || true

echo "▸ Architectures:"
lipo -info "$APP/Contents/MacOS/$APP_NAME" || true

echo ""
echo "✅ Done → $APP"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "   Ad-hoc signed: after a rebuild, re-grant Screen Recording in System Settings"
  echo "   (remove the old SnapMark entry, add the new one), then relaunch."
  echo "   Run ./Packaging/make_dev_cert.sh once to make the permission survive rebuilds."
else
  echo "   Signed with a stable identity: privacy permissions survive rebuilds."
fi
