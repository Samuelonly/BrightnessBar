#!/bin/bash
# Build BrightnessBar and assemble a runnable .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/BrightnessBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BrightnessBar "$APP/Contents/MacOS/BrightnessBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>BrightnessBar</string>
    <key>CFBundleIdentifier</key><string>local.brightnessbar</string>
    <key>CFBundleName</key><string>BrightnessBar</string>
    <key>CFBundleDisplayName</key><string>屏幕亮度</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo
echo "完成：$APP"
echo "运行测试：open \"$APP\""
echo "长期使用：把 $APP 拖到「应用程序」，并在 系统设置 → 通用 → 登录项 中添加它。"
