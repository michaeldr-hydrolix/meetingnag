#!/bin/bash
# Builds MeetingNag.pkg, a standard macOS installer (double-click to install).
# Run once on a Mac with Apple's Command Line Tools:   bash build-pkg.sh
#
# Optional signing, needed only to share the .pkg with other people without Gatekeeper warnings:
#   APP_SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   PKG_SIGN_ID="Developer ID Installer: Your Name (TEAMID)" \
#   NOTARY_PROFILE="my-notary-profile" \
#   bash build-pkg.sh
set -euo pipefail

VERSION="1.5"
APP_NAME="MeetingNag"
LABEL="io.local.meetingnag"
SRC="$(cd "$(dirname "$0")" && pwd)"
BUILD="$SRC/build"
STAGE="$BUILD/root"
APP="$STAGE/Applications/$APP_NAME.app"
OUT="$SRC/$APP_NAME-$VERSION.pkg"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are required. A dialog will open — click Install, then re-run."
  xcode-select --install || true
  exit 1
fi

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/pkgs" "$BUILD/resources"

echo "→ Compiling (Apple silicon + Intel)…"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos13.0" \
    -framework AppKit -framework AVFoundation -framework EventKit -framework IOKit \
    "$SRC/main.swift" -o "$BUILD/$APP_NAME-$ARCH"
done
lipo -create "$BUILD/$APP_NAME-arm64" "$BUILD/$APP_NAME-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"

cp "$SRC/uninstall.sh" "$APP/Contents/Resources/uninstall.sh"
chmod 755 "$APP/Contents/Resources/uninstall.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$LABEL</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>MeetingNag reads your calendar to alert you before meetings start.</string>
  <key>NSCalendarsUsageDescription</key><string>MeetingNag reads your calendar to alert you before meetings start.</string>
  <key>NSAppleEventsUsageDescription</key><string>MeetingNag raises the volume during meeting alerts.</string>
</dict>
</plist>
PLIST

echo "→ Signing app…"
if [[ -n "${APP_SIGN_ID:-}" ]]; then
  cat > "$BUILD/entitlements.plist" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.automation.apple-events</key><true/>
  <key>com.apple.security.personal-information.calendars</key><true/>
</dict></plist>
ENT
  codesign --force --timestamp --options runtime --entitlements "$BUILD/entitlements.plist" \
    --sign "$APP_SIGN_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi

echo "→ Building packages…"
chmod 755 "$SRC/pkg/scripts-app/"* "$SRC/pkg/scripts-lidmode/"*

# Install exactly to /Applications (don't "relocate" onto an older copy elsewhere).
pkgbuild --analyze --root "$STAGE" "$BUILD/component.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/component.plist"

pkgbuild --root "$STAGE" --component-plist "$BUILD/component.plist" \
  --identifier "$LABEL.app" --version "$VERSION" \
  --scripts "$SRC/pkg/scripts-app" --install-location / \
  "$BUILD/pkgs/app.pkg" >/dev/null

pkgbuild --nopayload --identifier "$LABEL.lidmode" --version "$VERSION" \
  --scripts "$SRC/pkg/scripts-lidmode" \
  "$BUILD/pkgs/lidmode.pkg" >/dev/null

sed "s/__VERSION__/$VERSION/g" "$SRC/pkg/Distribution.xml" > "$BUILD/Distribution.xml"
cp "$SRC/pkg/resources/"* "$BUILD/resources/"

SIGN_ARGS=()
if [[ -n "${PKG_SIGN_ID:-}" ]]; then SIGN_ARGS=(--sign "$PKG_SIGN_ID" --timestamp); fi

productbuild --distribution "$BUILD/Distribution.xml" \
  --resources "$BUILD/resources" --package-path "$BUILD/pkgs" \
  ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$OUT" >/dev/null

if [[ -n "${NOTARY_PROFILE:-}" && -n "${PKG_SIGN_ID:-}" ]]; then
  echo "→ Notarizing (a few minutes)…"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
fi

rm -rf "$BUILD"
echo ""
echo "✓ Built $OUT"
echo "  Double-click it to install. It replaces any previous MeetingNag and keeps your settings."
if [[ -z "${PKG_SIGN_ID:-}" ]]; then
  echo "  Unsigned: fine on this Mac. On other Macs, macOS blocks it until you click"
  echo "  System Settings › Privacy & Security › Open Anyway (or sign it, see top of script)."
fi
