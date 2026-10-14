#!/bin/zsh
set -eu
cd "$(dirname "$0")"
APP="axbro.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p Runtime .build
for ARCH in x86_64 arm64; do
    xcrun swiftc -parse-as-library -O -target "$ARCH-apple-macosx13.0" Source/CodexMini.swift Source/ReminderPolicy.swift Source/FloatingPlacement.swift Source/Weather.swift -o ".build/CodexMini-$ARCH" -framework AppKit -framework SwiftUI -framework CoreLocation
    xcrun swiftc -parse-as-library -O -target "$ARCH-apple-macosx13.0" Source/Lifecycle.swift -o ".build/Lifecycle-$ARCH" -framework AppKit
 done
lipo -create .build/CodexMini-x86_64 .build/CodexMini-arm64 -output "$APP/Contents/MacOS/axbro"
lipo -create .build/Lifecycle-x86_64 .build/Lifecycle-arm64 -output Runtime/CodexMiniLifecycle
codesign --force --sign - Runtime/CodexMiniLifecycle
cp Source/Assets/WeatherReference.png "$APP/Contents/Resources/WeatherReference.png"
cp Source/monitor.py "$APP/Contents/Resources/monitor.py"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>axbro</string>
<key>CFBundleIdentifier</key><string>local.dean.CodexMini</string>
<key>CFBundleName</key><string>axbro</string>
<key>CFBundleDisplayName</key><string>axbro</string>
<key>CFBundleVersion</key><string>21</string>
<key>CFBundleShortVersionString</key><string>1.14.3</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocationWhenInUseUsageDescription</key><string>使用当前位置获取天气，显示昼夜及天气背景。</string>
<key>NSLocationUsageDescription</key><string>使用当前位置获取天气，显示昼夜及天气背景。</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
cp Source/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
