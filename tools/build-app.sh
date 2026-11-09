#!/bin/sh
# 맥용 단독 실행 앱(Chanelu.app) 만들기 → dist/Chanelu-mac.zip
# 먼저 tools/build-desktop.sh 로 bin/chanelu-desktop 을 빌드해 두세요.
set -e
cd "$(dirname "$0")/.."
VERSION=$(node -p "require('./package.json').version" 2>/dev/null || echo 0.0.0)
APP=dist/Chanelu.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp bin/chanelu-desktop "$APP/Contents/MacOS/Chanelu"
cp media/sheet.png "$APP/Contents/Resources/sheet.png"

# 아이콘
ICONSET=dist/AppIcon.iconset && mkdir -p $ICONSET
for s in 16 32 128 256; do
  sips -z $s $s media/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  d=$((s*2)); sips -z $d $d media/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf $ICONSET

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>Chanelu</string>
  <key>CFBundleIdentifier</key><string>com.lalalalala00.chanelu</string>
  <key>CFBundleName</key><string>Chanelu</string>
  <key>CFBundleDisplayName</key><string>Baby Flower Chanelu</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 lalalalala00. Chanelu artwork all rights reserved.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --deep -s - "$APP"
(cd dist && ditto -c -k --keepParent Chanelu.app Chanelu-mac.zip)
ls -la dist
