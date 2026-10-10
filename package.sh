#!/bin/zsh
# Builds a universal app and a DMG suitable for copying to another Mac.
set -e
cd "${0:A:h}"

DFM_UNIVERSAL=1 DFM_DISTRIBUTION=1 ./build.sh

APP=build/Kermo.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $APP/Contents/Info.plist)
DMG=dist/Kermo-${VERSION}-universal.dmg
PKG=dist/Kermo-${VERSION}-universal.pkg
STAGE=$(mktemp -d)
trap 'rm -rf $STAGE' EXIT

mkdir -p dist
rm -f $DMG $DMG.sha256 $PKG $PKG.sha256
ditto --noextattr --noacl $APP $STAGE/Kermo.app
codesign --force --options runtime --sign - $STAGE/Kermo.app
pkgbuild --quiet --component $STAGE/Kermo.app --install-location /Applications $PKG
ln -s /Applications $STAGE/Applications
cat > $STAGE/INSTALL.txt <<'EOF'
Kermo requires macOS 14 or later.

1. Drag Kermo.app to the Applications shortcut.
2. Open Kermo from Applications. macOS blocks the first launch because this build is not notarized by Apple.
3. macOS 15 or later: open System Settings > Privacy & Security, click Open Anyway next to Kermo, and confirm.
   macOS 14: Control-click Kermo in Applications, choose Open, and confirm.

This is only required on the first launch.
EOF

hdiutil create -quiet -volname Kermo -srcfolder $STAGE -ov -format UDZO $DMG
hdiutil verify $DMG >/dev/null
shasum -a 256 $PKG > $PKG.sha256
shasum -a 256 $DMG > $DMG.sha256

echo "→ $PKG"
echo "→ $DMG"