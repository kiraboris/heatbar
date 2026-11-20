#!/bin/bash
# Builds a universal HeatBar.app and packages dist/HeatBar-<version>.zip
# (HeatBar.app, install.sh, uninstall.sh, README.md).
#
# Optional environment:
#   BUNDLE_ID       bundle identifier, also the launch agent label (default: local.heatbar)
#   SIGN_ID         codesign identity, e.g. "Developer ID Application: Name (TEAMID)" (default: ad hoc)
#   NOTARY_PROFILE  notarytool keychain profile; when set, the app is notarized and stapled
set -euo pipefail
cd "$(dirname "$0")"
VERSION="2.1.1"
LABEL="${BUNDLE_ID:-local.heatbar}"
SIGN_ID="${SIGN_ID:--}"
NAME="HeatBar-$VERSION"

rm -rf build dist
mkdir -p build/HeatBar.app/Contents/MacOS build/HeatBar.app/Contents/Resources "dist/$NAME"
cp Resources/AppIcon.icns Resources/Assets.car build/HeatBar.app/Contents/Resources/
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13" Sources/*.swift \
    -o "build/HeatBar-$arch" -framework AppKit -framework UserNotifications
done
lipo -create build/HeatBar-arm64 build/HeatBar-x86_64 -output build/HeatBar.app/Contents/MacOS/HeatBar

cat > build/HeatBar.app/Contents/Info.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>CFBundleIdentifier</key><string>$LABEL</string>
 <key>CFBundleName</key><string>HeatBar</string>
 <key>CFBundleExecutable</key><string>HeatBar</string>
 <key>CFBundleIconFile</key><string>AppIcon</string>
 <key>CFBundleIconName</key><string>AppIcon</string>
 <key>CFBundlePackageType</key><string>APPL</string>
 <key>CFBundleShortVersionString</key><string>$VERSION</string>
 <key>CFBundleVersion</key><string>$VERSION</string>
 <key>LSUIElement</key><true/>
 <key>LSMinimumSystemVersion</key><string>13.0</string>
 <key>NSHumanReadableCopyright</key><string>Open source</string>
 <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict></plist>
PL
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep -s - build/HeatBar.app
else
  codesign --force --options runtime --timestamp -s "$SIGN_ID" build/HeatBar.app
fi
codesign --verify --strict build/HeatBar.app

if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ "$SIGN_ID" != "-" ] || { echo "Notarization needs SIGN_ID (a Developer ID identity)"; exit 1; }
  ditto -c -k --keepParent build/HeatBar.app build/notarize.zip
  xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple build/HeatBar.app
fi

ditto build/HeatBar.app "dist/$NAME/HeatBar.app"
cp scripts/install.sh scripts/uninstall.sh README.md LICENSE "dist/$NAME/"
(cd dist && ditto -c -k --keepParent "$NAME" "$NAME.zip")
echo "Built $(pwd)/dist/$NAME.zip"
