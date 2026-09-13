#!/bin/bash
# Bopomix release build: Release build -> Developer ID signing (hardened runtime)
# -> notarize + staple the input method -> embed it in the installer as the
# NotarizedArchives zip the installer expects -> sign + notarize the installer
# -> dmg -> notarize + staple the dmg.
#
# Usage:  tools/release/build-release.sh [--skip-notarize]
# Needs:  a "Developer ID Application" identity in the login keychain and a
#         notarytool keychain profile (xcrun notarytool store-credentials <name>).
#
# Draft written 2026-09-13; intended home: tools/release/build-release.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
IDENTITY="${BOPOMIX_SIGN_IDENTITY:-Developer ID Application: Yichen chu (HG5RRBKA8T)}"
PROFILE="${BOPOMIX_NOTARY_PROFILE:-bopomix}"
DERIVED="$REPO/build-release"
OUT="$REPO/dist"
SKIP_NOTARIZE=0
[ "${1:-}" = "--skip-notarize" ] && SKIP_NOTARIZE=1

log() { printf '\n==> %s\n' "$*"; }

notarize() {  # notarize <file>  (zip or dmg); waits for the result
  local f="$1"
  if [ "$SKIP_NOTARIZE" = 1 ]; then log "skip notarize: $f"; return; fi
  log "notarize $(basename "$f")"
  xcrun notarytool submit "$f" --keychain-profile "$PROFILE" --wait
}

rm -rf "$DERIVED" "$OUT"; mkdir -p "$OUT"

# 1. Release build of both targets, ad-hoc signed by Xcode; we re-sign below.
log "xcodebuild Release (Bopomix + BopomixInstaller)"
xcodebuild -project "$REPO/Bopomix.xcodeproj" -scheme BopomixInstaller -configuration Release \
  -derivedDataPath "$DERIVED" CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" \
  build | grep -E "BUILD (SUCCEEDED|FAILED)|error:"

PRODUCTS="$DERIVED/Build/Products/Release"
IME="$PRODUCTS/Bopomix.app"
INSTALLER="$PRODUCTS/BopomixInstaller.app"
[ -d "$IME" ] && [ -d "$INSTALLER" ] || { echo "build products missing"; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$IME/Contents/Info.plist")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$IME/Contents/Info.plist")
log "version $VERSION (r$BUILD)"

# 2. Sign the input method: nested code first (frameworks, helpers), then the bundle.
sign() {  # sign <path>
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$1"
}
log "sign Bopomix.app"
find "$IME/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' -o -name '*.xpc' -o -name '*.app' \) -print0 \
  | while IFS= read -r -d '' nested; do sign "$nested"; done
sign "$IME"
codesign --verify --deep --strict --verbose=2 "$IME"

# 3. Zip -> notarize -> staple the app -> re-zip (the stapled copy is what ships).
IME_ZIP="$OUT/Bopomix-r$BUILD.zip"
ditto -c -k --keepParent "$IME" "$IME_ZIP"
notarize "$IME_ZIP"
if [ "$SKIP_NOTARIZE" = 0 ]; then
  xcrun stapler staple "$IME"
  rm -f "$IME_ZIP"; ditto -c -k --keepParent "$IME" "$IME_ZIP"
fi

# 4. Installer: drop the dev-mode embedded app, embed the notarized zip
#    (ArchiveUtil expects Resources/NotarizedArchives/<appName>-r<CFBundleVersion>.zip
#    and refuses to run if the dev bundle is also present).
log "prepare BopomixInstaller.app"
RES="$INSTALLER/Contents/Resources"
rm -rf "$RES/Bopomix.app"
mkdir -p "$RES/NotarizedArchives"
cp "$IME_ZIP" "$RES/NotarizedArchives/"
INSTALLER_BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLER/Contents/Info.plist")
[ "$INSTALLER_BUILD" = "$BUILD" ] || { echo "installer CFBundleVersion $INSTALLER_BUILD != IME $BUILD (ArchiveUtil looks up the zip by the installer's own version)"; exit 1; }

log "sign BopomixInstaller.app"
find "$INSTALLER/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \) -print0 \
  | while IFS= read -r -d '' nested; do sign "$nested"; done
sign "$INSTALLER"
codesign --verify --deep --strict --verbose=2 "$INSTALLER"

INSTALLER_ZIP="$OUT/BopomixInstaller-r$BUILD.zip"
ditto -c -k --keepParent "$INSTALLER" "$INSTALLER_ZIP"
notarize "$INSTALLER_ZIP"
[ "$SKIP_NOTARIZE" = 0 ] && xcrun stapler staple "$INSTALLER"
rm -f "$INSTALLER_ZIP"

# 5. dmg with the installer, notarize + staple.
log "dmg"
STAGE="$OUT/dmg-root"; rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$INSTALLER" "$STAGE/Install Bopomix 安裝混打注音.app"
DMG="$OUT/Bopomix-$VERSION.dmg"
hdiutil create -volname "Bopomix $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
sign "$DMG"
notarize "$DMG"
[ "$SKIP_NOTARIZE" = 0 ] && xcrun stapler staple "$DMG"
rm -rf "$STAGE"

log "done"
ls -la "$OUT"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 || true
