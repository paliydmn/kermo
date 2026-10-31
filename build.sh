#!/bin/zsh
# Builds build/Kermo.app (no Xcode needed, Command Line Tools are enough).
set -e
cd "${0:A:h}"
BUILD_ARGS=(-c release --product DFileManager)
if [[ ${DFM_UNIVERSAL:-0} == 1 ]]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
BIN_DIR=$(swift build $BUILD_ARGS --show-bin-path)
swift build $BUILD_ARGS
APP=build/Kermo.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS
cp $BIN_DIR/DFileManager $APP/Contents/MacOS/Kermo   # SwiftPM target keeps its old name
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
  <key>CFBundleShortVersionString</key><string>1.6</string>
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
