#!/bin/bash
# Builds a Release MacDM.app with yt-dlp and ffmpeg inside, checks it for personal data,
# and packs dist/MacDM.dmg.
#
# Usage: scripts/build-dmg.sh
# Signing: ad-hoc by default. With a Developer ID, run
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$(pwd)"
# Build outside the home folder: the linker records the build folder's path in the program.
BUILD="/tmp/macdm-release-build"
DIST="$SRC/dist"
APP="$BUILD/Build/Products/Release/MacDM.app"
IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Fetching tools (checksum-verified)"
scripts/fetch-tools.sh

echo "==> Building Release (Apple Silicon)"
rm -rf "$BUILD" "$DIST"; mkdir -p "$DIST"
# The prefix-map flags rewrite your folder path inside the compiled program,
# so the published app doesn't contain your username.
xcodebuild build -project MacDM.xcodeproj -scheme MacDM -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" -quiet \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  OTHER_SWIFT_FLAGS="\$(inherited) -file-prefix-map $SRC=/MacDM -debug-prefix-map $SRC=/MacDM" \
  OTHER_CFLAGS="\$(inherited) -ffile-prefix-map=$SRC=/MacDM" \
  OTHER_LDFLAGS="\$(inherited) -Wl,-S" 2>&1 | grep -v -E "SDKExplicitPrecompiledModules|while processing|no debug symbols" || true
[[ -d "$APP" ]] || { echo "build failed"; exit 1; }

echo "==> Adding yt-dlp, ffmpeg, the Chrome extension and notices"
HELPERS="$APP/Contents/Helpers"; RES="$APP/Contents/Resources"
mkdir -p "$HELPERS" "$RES"
cp vendor/ffmpeg "$HELPERS/ffmpeg"
# yt-dlp ships as a program plus an "_internal" folder of libraries (ditto keeps links intact).
# It lives in Resources/yt-dlp: macOS treats everything inside Helpers as code that must be signed
# file by file, but yt-dlp's folder also holds plain data files.
YTDIR="$RES/yt-dlp"; mkdir -p "$YTDIR"
cp vendor/yt-dlp-dist/yt-dlp_macos "$YTDIR/yt-dlp"
ditto vendor/yt-dlp-dist/_internal "$YTDIR/_internal"

# MacDM is Apple Silicon only, so drop the unused Intel half of each library (saves ~55 MB).
# The yt-dlp program itself is left whole: it carries data inside it that thinning would cut off.
# Set THIN_INTEL=0 to skip this.
if [[ "${THIN_INTEL:-1}" == "1" ]]; then
  thinned=0
  while IFS= read -r -d '' f; do
    archs="$(lipo -archs "$f" 2>/dev/null || true)"
    if [[ "$archs" == *x86_64* && "$archs" == *arm64* ]]; then
      lipo -thin arm64 "$f" -output "$f.thin" && mv "$f.thin" "$f"; thinned=$((thinned+1))
    fi
  done < <(find "$YTDIR/_internal" -type f -not -path "*.framework/*" -print0)
  echo "   removed the Intel half of $thinned libraries"
fi
cp THIRD-PARTY-NOTICES.md "$RES/"
cp assets/AppIcon.icns "$RES/AppIcon.icns"
mkdir -p "$RES/ChromeExtension"
cp ChromeExtension/manifest.json ChromeExtension/background.js ChromeExtension/content.js ChromeExtension/popup.html "$RES/ChromeExtension/"

echo "==> Signing (identity: ${IDENTITY/#-/ad-hoc})"
# Hardened runtime + timestamp are only meaningful (and required for notarization) with a real identity.
EXTRA=(); [[ "$IDENTITY" != "-" ]] && EXTRA=(--options runtime --timestamp)
# Inside-out: helpers first, then the Safari extension, then the app. Entitlements are
# read back from what Xcode already signed with, so they are kept.
# yt-dlp's libraries first (every program file inside must carry its own signature)...
# Python.framework is a bundle that already carries yt-dlp's own valid signature; it is left as shipped.
signed=0
while IFS= read -r -d '' f; do
  if lipo -archs "$f" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" ${EXTRA[@]+"${EXTRA[@]}"} "$f" || { echo "✖ could not sign $f"; exit 1; }
    signed=$((signed+1))
  fi
done < <(find "$YTDIR/_internal" -type f -not -path "*.framework/*" -print0)
echo "   signed $signed yt-dlp libraries"
# ...then the two programs.
for tool in "$YTDIR/yt-dlp" "$HELPERS/ffmpeg"; do
  codesign --force --sign "$IDENTITY" ${EXTRA[@]+"${EXTRA[@]}"} --entitlements scripts/helper.entitlements "$tool"
done
ENT="$(mktemp -d /tmp/macdm-ent.XXXXXX)"
APPEX="$APP/Contents/PlugIns/SafariExtension.appex"
codesign -d --entitlements :- "$APPEX" > "$ENT/appex.plist" 2>/dev/null
codesign -d --entitlements :- "$APP"   > "$ENT/app.plist"   2>/dev/null
codesign --force --sign "$IDENTITY" ${EXTRA[@]+"${EXTRA[@]}"} --entitlements "$ENT/appex.plist" "$APPEX"
codesign --force --sign "$IDENTITY" ${EXTRA[@]+"${EXTRA[@]}"} --entitlements "$ENT/app.plist" "$APP"
rm -rf "$ENT"
codesign --verify --deep --strict "$APP"
echo "   signature OK"

# MacDM must show in the Dock while it runs; LSUIElement would hide it.
if [[ "$(/usr/libexec/PlistBuddy -c "Print :LSUIElement" "$APP/Contents/Info.plist" 2>/dev/null)" == "true" ]]; then
  echo "✖ Info.plist has LSUIElement=true: the app would have no Dock icon"; exit 1
fi

echo "==> Running the bundled tools (the first run of yt-dlp is slow, once)"
YT_VERSION="$(env -i PATH=/usr/bin:/bin "$YTDIR/yt-dlp" --version)" || { echo "bundled yt-dlp does not run"; exit 1; }
FF_VERSION="$(env -i PATH=/usr/bin:/bin "$HELPERS/ffmpeg" -version | head -1 | cut -d' ' -f3)" || { echo "bundled ffmpeg does not run"; exit 1; }
echo "   yt-dlp $YT_VERSION, ffmpeg $FF_VERSION"

echo "==> Checking the app for personal data"
scripts/check-privacy.sh "$APP"

echo "==> Creating the DMG"
STAGE="$(mktemp -d /tmp/macdm-dmg.XXXXXX)"
cp -R "$APP" "$STAGE/MacDM.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "MacDM" -srcfolder "$STAGE" -ov -format UDZO "$DIST/MacDM.dmg" -quiet
rm -rf "$STAGE"

echo "==> Checking the DMG for personal data"
scripts/check-privacy.sh "$DIST/MacDM.dmg"

# The build folder holds a copy of the app; make macOS forget it so Safari lists only one MacDM.
scripts/clean-macdm-copies.sh >/dev/null 2>&1 || true

echo; echo "✔ Built $DIST/MacDM.dmg ($(du -h "$DIST/MacDM.dmg" | cut -f1))"
