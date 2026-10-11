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

# Safari 扩展独立容器 App(不依赖桌面完整版):扩展数据通路在 JS 内直连
# relay API,容器仅承载 appex。失败仅告警(主 App 打包不受影响)。
# -allowProvisioningUpdates:让已登录 Apple ID 的机器自动补描述文件;
# CI 无账号时照样失败走告警路径。
echo "==> xcodebuild Release (standalone Safari container)"
if ! xcodebuild -quiet -allowProvisioningUpdates \
      -workspace UPasswords.xcworkspace -scheme UPasswordsSafari \
      -configuration Release build 2>/dev/null; then
  echo "    WARNING: standalone Safari app build failed — skipping it"
fi
# ls 在无匹配时非零退出,pipefail 会把它升级成整脚本失败(set -e),
# 吞掉 ls 的退出码——找不到就当没有,继续打主 App。
SAFARI_APP="$(ls -dt "$HOME/Library/Developer/Xcode/DerivedData/UPasswords-"*/Build/Products/Release/UPasswordsSafari.app 2>/dev/null | head -1 || true)"
if [ -n "$SAFARI_APP" ]; then
  DEST="$OUT_DIR/UPasswords for Safari.app"
  rm -rf "$DEST"
  cp -R "$SAFARI_APP" "$DEST"
  # xcodebuild 已整包签名(含 appex 的 sandbox/app-group entitlements),不再重签
  xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
  echo "==> packaged standalone Safari app ($(du -sh "$DEST" | cut -f1))"
else
  echo "    WARNING: standalone Safari app not found in build products"
fi

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
    <string>$(date +%y%m%d%H%M)</string>
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

# 稳定签名:优先用开发证书,找不到才回退 ad-hoc。
# ad-hoc 签名按代码哈希生效——每次重打包哈希都变,钥匙串把新包当陌生程序,
# 周期性钥匙串访问(如云同步令牌)会被 macOS 逐次弹指纹/密码授权;
# 开发证书身份跨构建稳定,授权一次永久生效。
# entitlements 只带应用组:应用组容器(Group Containers)在 TCC 里属
# 「其他 App 的数据」,不带该授权时 SafariSnapshotBridge 每次推送快照都会弹窗。
# 注意:不加 --deep——appex 的 sandbox/app-group entitlements 必须保持
# xcodebuild 给它的独立签名,父包的 entitlements 覆盖上去会毁掉沙盒配置。
echo "==> codesign"
# grep 无匹配时非零退出,pipefail 会升级成整脚本失败;吞掉让空串走 ad-hoc 回退。
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"([^"]+)".*/\1/' || true)"
SIGN_ID="${IDENTITY:--}"
# 签名顺序自内向外:SPM 资源 bundle 无签名须先逐个签掉;appex 保留 xcodebuild
# 的独立签名不动;最后签父包。全程不用 --deep——它会用父包 entitlements
# 覆盖 appex 的 sandbox/app-group,导致 Safari 拒绝托管扩展。
for bundle in "$CONTENTS/MacOS/"*.bundle; do
  [ -d "$bundle" ] || continue
  codesign --force --sign "$SIGN_ID" "$bundle"
done
ENTITLEMENTS="Apple/macOS/UPasswords-dist.entitlements"
codesign --force --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP"
if [ -n "$IDENTITY" ]; then
  echo "    signed with development identity: $IDENTITY"
else
  echo "    signed ad-hoc (no development identity found on this machine)"
fi

echo "==> $APP"
du -sh "$APP"

# /Applications 已有安装拷贝时同步替换(同 bundle id,Dock/LaunchServices 会优先
# 打开 /Applications 那份——不同步的话用户点开的永远是旧版本)。
if [ -d "/Applications/UPasswords.app" ] && [ "$OUT_DIR" != "/Applications" ]; then
  rm -rf "/Applications/UPasswords.app"
  cp -R "$APP" "/Applications/UPasswords.app"
  xattr -dr com.apple.quarantine "/Applications/UPasswords.app" 2>/dev/null || true
  echo "==> synced to /Applications/UPasswords.app"
fi

# 独立 Safari 容器 App 同步安装(Safari 扩展的稳定宿主,替代 DerivedData)
if [ -n "$SAFARI_APP" ] && [ -d "$OUT_DIR/UPasswords for Safari.app" ] && [ "$OUT_DIR" != "/Applications" ]; then
  rm -rf "/Applications/UPasswords for Safari.app"
  cp -R "$OUT_DIR/UPasswords for Safari.app" "/Applications/UPasswords for Safari.app"
  xattr -dr com.apple.quarantine "/Applications/UPasswords for Safari.app" 2>/dev/null || true
  echo "==> synced to /Applications/UPasswords for Safari.app"
fi

# 扩展注册锚定到成品包位置(独立容器 App);DerivedData 注册易被 clean 清掉。
if [ -n "$SAFARI_APP" ] && [ -d "$OUT_DIR/UPasswords for Safari.app" ]; then
  pluginkit -r "$SAFARI_APP" 2>/dev/null || true
  if [ -d "/Applications/UPasswords for Safari.app" ]; then
    pluginkit -a "/Applications/UPasswords for Safari.app" 2>/dev/null || true
  else
    pluginkit -a "$OUT_DIR/UPasswords for Safari.app" 2>/dev/null || true
  fi
  echo "==> extension registration anchored to standalone app"
fi
