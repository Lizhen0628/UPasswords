#!/bin/bash
# Bundle the SPM executable into a runnable UPasswords.app.
# Usage: ./scripts/make-app.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
CONFIG="${CONFIG:-release}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/UPasswords"
APP="$OUT_DIR/UPasswords.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "==> copying binary + module bundle"
cp "$BIN" "$CONTENTS/MacOS/UPasswords"
# SPM resources land next to the binary as UPasswords_UPasswords.bundle
if [ -d ".build/$CONFIG/UPasswords_UPasswords.bundle" ]; then
  cp -R ".build/$CONFIG/UPasswords_UPasswords.bundle" "$CONTENTS/MacOS/"
fi

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>UPasswords</string>
    <key>CFBundleDisplayName</key>
    <string>UPasswords</string>
    <key>CFBundleIdentifier</key>
    <string>com.upasswords.UPasswords</string>
    <key>CFBundleVersion</key>
    <string>1000</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>UPasswords</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

# 应用图标(程序坞/Finder/锁屏展示用)
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi
# 菜单栏三钥匙 template 图
if [ -f "Resources/MenuBarKeys.png" ]; then
  cp "Resources/MenuBarKeys.png" "$CONTENTS/Resources/MenuBarKeys.png"
fi

echo "==> $APP"
du -sh "$APP"
