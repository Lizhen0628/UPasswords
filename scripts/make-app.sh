#!/bin/bash
# Bundle the macOS SPM executable into a runnable UPasswords.app.
# Usage: ./scripts/make-app.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
CONFIG="${CONFIG:-release}"
APP_PKG="Apple/macOS"

echo "==> swift build -c $CONFIG ($APP_PKG)"
(cd "$APP_PKG" && swift build -c "$CONFIG")

BIN="$APP_PKG/.build/$CONFIG/UPasswords"
APP="$OUT_DIR/UPasswords.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

echo "==> copying binary + module bundle"
cp "$BIN" "$CONTENTS/MacOS/UPasswords"
# SPM 资源 bundle 落在 .build/<config>/ 下:应用自身的 UPasswords_UPasswords.bundle
# (菜单栏图标)与依赖包的 UPasswordsCore_UPasswordsCore.bundle(lproj 字符串表)——
# 必须全部拷入,漏掉 Core bundle 会让 L10n 取词全部回显键名。
for bundle in "$APP_PKG/.build/$CONFIG/"*.bundle; do
  [ -d "$bundle" ] || continue
  cp -R "$bundle" "$CONTENTS/MacOS/"
done

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
if [ -f "$APP_PKG/Resources/AppIcon.icns" ]; then
  cp "$APP_PKG/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi
# 菜单栏三钥匙 template 图随 SPM 资源打入 UPasswords_UPasswords.bundle(见上),
# 由 StatusItemController 经 AppResources.bundle 加载。

echo "==> $APP"
du -sh "$APP"
