#!/bin/zsh
# Matrix3DSaverX — full release build (classic .saver)
# Usage: ./tools/release.sh
#
# Requires tools/local-signing.env (see local-signing.env.example) and a
# one-time `xcrun notarytool store-credentials` profile named in PROFILE.
#
# Do NOT staple the .saver (Contents/CodeResources breaks Auswahlbild).
# The DMG may be stapled safely.
#
# Appex (App + Extension) is gated via project.yml → include enable and
# is not part of this release path.
set -e

cd "$(dirname "$0")/.."

LOCAL_ENV="tools/local-signing.env"
if [[ ! -f "$LOCAL_ENV" ]]; then
  echo "ERROR: $LOCAL_ENV is missing. Copy tools/local-signing.env.example and fill in TEAM_ID, BUNDLE_ID, PROFILE."
  exit 1
fi
# shellcheck disable=SC1090
source "$LOCAL_ENV"
: "${TEAM_ID:?TEAM_ID missing in $LOCAL_ENV}"
: "${BUNDLE_ID:?BUNDLE_ID missing in $LOCAL_ENV}"
: "${PROFILE:?PROFILE missing in $LOCAL_ENV}"
SIGN_ID="${SIGN_ID:-Developer ID Application}"

DERIVED="build/DerivedData"
SAVER="$DERIVED/Build/Products/Release/Matrix3DSaverX.saver"
ZIP="build/Matrix3DSaverX-notarize.zip"
DMG_STAGING="build/dmg-staging"

# ── 0. Bump build number ──────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════╗"
echo "║  0/5  Version hochzählen                 ║"
echo "╚══════════════════════════════════════════╝"

CURRENT_BUILD=$(rg 'CURRENT_PROJECT_VERSION:\s*(\d+)' project.yml -o --replace '$1' | head -1)
if [[ -z "$CURRENT_BUILD" ]]; then
  echo "ERROR: CURRENT_PROJECT_VERSION nicht in project.yml gefunden"
  exit 1
fi
NEW_BUILD=$((CURRENT_BUILD + 1))
MARKETING=$(rg 'MARKETING_VERSION:\s*"([^"]+)"' project.yml -o --replace '$1' | head -1)

sed -i '' "s/CURRENT_PROJECT_VERSION: $CURRENT_BUILD/CURRENT_PROJECT_VERSION: $NEW_BUILD/g" project.yml
if [[ -f project-appex.yml ]]; then
  # Appex targets can lag behind if they were not bumped in lockstep.
  sed -i '' "s/CURRENT_PROJECT_VERSION: [0-9][0-9]*/CURRENT_PROJECT_VERSION: $NEW_BUILD/g" project-appex.yml
fi

echo "  Marketing-Version : $MARKETING"
echo "  Build-Nummer      : $CURRENT_BUILD → $NEW_BUILD"
echo ""

DMG="build/Matrix3DSaverX-${MARKETING}-${NEW_BUILD}.dmg"

# ── 1. Build ──────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════╗"
echo "║  1/5  Release-Build                      ║"
echo "╚══════════════════════════════════════════╝"

xcodegen generate

xcodebuild -scheme Matrix3DSaverX -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="$SIGN_ID" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build | grep -E "error:|Signing Identity|SUCCEEDED|FAILED"

echo "✅ Build OK"

# ── 2. Notarisierung ──────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  2/5  Notarisierung einreichen           ║"
echo "╚══════════════════════════════════════════╝"

rm -f "$ZIP"
ditto -c -k --keepParent "$SAVER" "$ZIP"

xcrun notarytool submit "$ZIP" \
  --keychain-profile "$PROFILE" \
  --wait

echo "✅ Notarisierung OK"

# ── 3. Kein .saver-Staple ─────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  3/5  .saver unstapled lassen            ║"
echo "╚══════════════════════════════════════════╝"

# Stapling writes Contents/CodeResources and can break the Wallpaper
# Auswahlbild (blue-swirl Default). DMG may still be stapled below.
rm -f "$SAVER/Contents/CodeResources"
echo "✅ .saver ohne Staple (Auswahlbild-sicher)"

# ── 4. DMG erstellen ──────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  4/5  DMG erstellen                      ║"
echo "╚══════════════════════════════════════════╝"

rm -f "$DMG"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$SAVER" "$DMG_STAGING/"

cat > "$DMG_STAGING/INSTALL.txt" << 'README'
Matrix 3D X — Installation
==========================

1. Doppelklick auf "Matrix3DSaverX.saver"
2. macOS fragt: "Nur für mich" oder "Für alle Benutzer" → wählen
3. Bildschirmschoner ist sofort in den Systemeinstellungen verfügbar
   als "Matrix 3D X"

Systemvoraussetzungen: macOS 13 oder neuer, Intel oder Apple Silicon
README

VERSION=$(defaults read "$(pwd)/$SAVER/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "$MARKETING")
BUILD=$(defaults read "$(pwd)/$SAVER/Contents/Info" CFBundleVersion 2>/dev/null || echo "$NEW_BUILD")

create-dmg \
  --volname "Matrix3DSaverX" \
  --volicon "Resources/AppIcon.icns" \
  --window-pos 200 120 \
  --window-size 600 400 \
  --icon-size 128 \
  --icon "Matrix3DSaverX.saver" 300 185 \
  --icon "INSTALL.txt" 480 185 \
  --hide-extension "Matrix3DSaverX.saver" \
  --no-internet-enable \
  "$DMG" \
  "$DMG_STAGING"

echo "✅ DMG erstellt: $DMG ($(du -sh "$DMG" | cut -f1))"
cp "$DMG" "build/Matrix3DSaverX.dmg"

# ── 5. DMG notarisieren + stapeln ─────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  5/5  DMG notarisieren + stapeln         ║"
echo "╚══════════════════════════════════════════╝"

xcrun notarytool submit "$DMG" \
  --keychain-profile "$PROFILE" \
  --wait

xcrun stapler staple "$DMG" || {
  echo "⚠️  Stapling DMG fehlgeschlagen (oft CloudKit/SSL auf neueren macOS)."
  echo "    Notarisierung war Accepted — Gatekeeper prüft online trotzdem."
}
cp "$DMG" "build/Matrix3DSaverX.dmg"
echo "✅ DMG Notarisierungs-Schritt fertig"

# ── Ergebnis ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  ✅  Release fertig                      ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Datei:    $DMG"
echo "  Version:  $VERSION ($BUILD)"
echo "  Größe:    $(du -sh "$DMG" | cut -f1)"
echo ""
xcrun stapler validate "$DMG" 2>/dev/null || echo "  (stapler validate DMG: Ticket noch nicht lokal)"
spctl -a -vv "$SAVER" 2>&1 | grep -E "source=|origin=" || true
echo "  (.saver bewusst unstapled)"

# Cache-Purge so Settings regenerates Auswahlbild from ScreenSaverThumbnail
DARWIN_CACHE="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
if [[ -n "${DARWIN_CACHE:-}" ]]; then
  rm -rf "$DARWIN_CACHE/com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
  rm -f  "$DARWIN_CACHE/com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.legacy-screenSaver"
fi
killall WallpaperAgent 2>/dev/null || true

DEST="${HOME}/Library/Screen Savers/Matrix3DSaverX.saver"
rm -rf "$DEST"
cp -R "$SAVER" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
rm -f "$DEST/Contents/CodeResources"
echo "  Installiert: $DEST"
