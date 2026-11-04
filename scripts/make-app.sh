#!/bin/bash
# ClaudeKun.app + ClaudeKun.dmg 만들기 → dist/
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/ClaudeKun.app
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ClaudeKun "$APP/Contents/MacOS/"

# 아이콘
ICONSET=dist/AppIcon.iconset && mkdir -p "$ICONSET"
.build/release/ClaudeKun --icon dist/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s dist/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) dist/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" dist/icon.png

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ClaudeKun</string>
  <key>CFBundleDisplayName</key><string>클로드쿤</string>
  <key>CFBundleIdentifier</key><string>com.chromeheartz.claudekun</string>
  <key>CFBundleExecutable</key><string>ClaudeKun</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
# ponytail: ad-hoc 서명. 남한테 배포할 땐 처음 한 번 우클릭→열기 필요 (Developer ID 공증은 유료 계정 생기면)
codesign --force --deep -s - "$APP"

STAGE=dist/dmg && mkdir -p "$STAGE" && cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname ClaudeKun -srcfolder "$STAGE" -ov -format UDZO dist/ClaudeKun.dmg >/dev/null
rm -rf "$STAGE"
echo "→ dist/ClaudeKun.app, dist/ClaudeKun.dmg"
