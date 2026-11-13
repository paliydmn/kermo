#!/bin/zsh
# Builds build/Kermo.app (no Xcode needed, Command Line Tools are enough).
set -e
cd "${0:A:h}"
BUILD_ARGS=(-c release --product DFileManager)
if [[ ${DFM_UNIVERSAL:-0} == 1 ]]; then
  # One architecture at a time, then one binary: with two --arch SwiftPM also builds SwiftTerm's build-time tool for
  # x86_64, which Command Line Tools can't link (no x86_64 libswiftCompatibility56).
  # Both land in the same folder: the first is set aside.
  ARM=($BUILD_ARGS --triple arm64-apple-macosx14.0) X86=($BUILD_ARGS --triple x86_64-apple-macosx14.0)
  BIN_DIR=$(swift build $ARM --show-bin-path) BIN=.build/Kermo-universal
  swift build $ARM && cp $BIN_DIR/DFileManager $BIN-arm64
  swift build $X86 && lipo -create -output $BIN $BIN-arm64 $(swift build $X86 --show-bin-path)/DFileManager
else
  BIN_DIR=$(swift build $BUILD_ARGS --show-bin-path)
  swift build $BUILD_ARGS
  BIN=$BIN_DIR/DFileManager   # SwiftPM target keeps its old name
fi
APP=build/Kermo.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp $BIN $APP/Contents/MacOS/Kermo
mkdir -p $APP/Contents/Resources
for b in $BIN_DIR/*.bundle(N); do cp -R $b $APP/Contents/Resources/; done   # SwiftPM resource bundles
cp bin/fm $APP/Contents/Resources/
ICNS=.build/AppIcon.icns
if [[ ! -e $ICNS || tools/icon.swift -nt $ICNS || tools/icon-art.png -nt $ICNS ]]; then   # redraw only when the icon script or its artwork changes
  SET=.build/AppIcon.iconset; rm -rf $SET; mkdir -p $SET
  swift tools/icon.swift $SET/icon_512x512@2x.png
  for f in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 512x512:512; do
    sips -z ${f#*:} ${f#*:} $SET/icon_512x512@2x.png --out $SET/icon_${f%:*}.png >/dev/null
  done
  iconutil -c icns $SET -o $ICNS
fi
cp $ICNS $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.dmn.dfilemanager</string>
  <key>CFBundleName</key><string>Kermo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Kermo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0.1</string>
  <key>CFBundleVersion</key><string>$(git rev-parse --short HEAD 2>/dev/null || echo dev)$(git diff --quiet HEAD 2>/dev/null || echo +)</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Palii</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Kermo checks the web addresses you saved with your servers (Tools ▸ Sites), and some of them are on this network.</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string></array>
  </dict></array>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.dmn.dfilemanager</string>
    <key>CFBundleURLSchemes</key><array><string>kermo</string></array>
  </dict></array>
</dict></plist>
EOF
ID="DFileManager Local Signing"   # created once by ./cert.sh
# Hardened runtime: dyld ignores DYLD_INSERT_LIBRARIES and loads only Apple-signed libraries, so no other program
# can run its code inside the app and borrow its Full Disk Access. For other Macs it still needs a Developer ID
# signature + notarization (Apple Developer account); this local identity is trusted by nobody else.
if [[ ${DFM_DISTRIBUTION:-0} != 1 ]] && security find-identity -p codesigning | grep -q "\"$ID\""; then
  codesign --force --options runtime --sign "$ID" $APP
else
  codesign --force --options runtime --sign - $APP   # ad-hoc: portable, but TCC grants reset on every rebuild; run ./cert.sh for local development
fi
echo "→ $APP"
