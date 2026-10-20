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
# One certificate for every release: macOS keeps Full Disk Access and other grants across updates (ad hoc, each
# build is a new app to it). Not notarized all the same: the first launch still needs Open Anyway.
ID="Kermo Release Signing"
if security find-identity -p codesigning | grep -q "\"$ID\""; then
  codesign --force --options runtime --sign "$ID" $STAGE/Kermo.app
elif [[ ${DFM_ADHOC:-0} == 1 ]]; then
  codesign --force --options runtime --sign - $STAGE/Kermo.app
else
  echo "No “$ID” in the keychain: restore it from its backup, or for a build that isn't a release run DFM_ADHOC=1 ./package.sh" >&2
  exit 1
fi
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
# Bare names, so `shasum -c` works in the folder the files were downloaded to.
(cd dist && shasum -a 256 ${PKG:t} > ${PKG:t}.sha256 && shasum -a 256 ${DMG:t} > ${DMG:t}.sha256)

echo "→ $PKG"
echo "→ $DMG"