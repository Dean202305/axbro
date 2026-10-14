#!/bin/zsh
set -eu
cd "$(dirname "$0")"
SUPPORT_DIR="$HOME/Library/Application Support/CodexMini"
APP_DEST="$HOME/Applications/axbro.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/local.dean.CodexMini.lifecycle.plist"
AGENT_LABEL="local.dean.CodexMini.lifecycle"
LEGACY_APP="$HOME/Applications/Codex Mini.app"
if [[ ! -e "$APP_DEST" && -d "$LEGACY_APP" ]]; then
    LEGACY_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$LEGACY_APP/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$LEGACY_ID" == "local.dean.CodexMini" ]]; then mv "$LEGACY_APP" "$APP_DEST"; fi
fi
if [[ -d "$APP_DEST" ]]; then
    EXISTING_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DEST/Contents/Info.plist" 2>/dev/null || true)
    if [[ "$EXISTING_ID" != "local.dean.CodexMini" ]]; then
        echo "同名应用不是 axbro，未覆盖：$APP_DEST"
        exit 1
    fi
fi
mkdir -p "$HOME/Applications" "$SUPPORT_DIR" "$HOME/Library/LaunchAgents"
if launchctl print "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID/$AGENT_LABEL"
fi
if [[ -x Runtime/CodexMiniLifecycle ]]; then
    cp Runtime/CodexMiniLifecycle "$SUPPORT_DIR/CodexMiniLifecycle.new"
else
    xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx13.0" Source/Lifecycle.swift -o "$SUPPORT_DIR/CodexMiniLifecycle.new" -framework AppKit
fi
codesign --force --sign - "$SUPPORT_DIR/CodexMiniLifecycle.new"
mv "$SUPPORT_DIR/CodexMiniLifecycle.new" "$SUPPORT_DIR/CodexMiniLifecycle"
ditto "axbro.app" "$APP_DEST"
if [[ -f "$APP_DEST/Contents/MacOS/CodexMini" ]]; then rm "$APP_DEST/Contents/MacOS/CodexMini"; fi
for OLD_RESOURCE in meters.py wb_credits.cjs; do
    rm -f "$APP_DEST/Contents/Resources/$OLD_RESOURCE"
done
if [[ -d "$APP_DEST/Contents/Resources/__pycache__" ]]; then rm -rf "$APP_DEST/Contents/Resources/__pycache__"; fi
codesign --verify --deep --strict "$APP_DEST"
if [[ -f "$AGENT_PLIST" ]]; then rm "$AGENT_PLIST"; fi
plutil -create xml1 "$AGENT_PLIST"
plutil -insert Label -string "$AGENT_LABEL" "$AGENT_PLIST"
plutil -insert ProgramArguments -xml '<array/>' "$AGENT_PLIST"
plutil -insert ProgramArguments.0 -string "$SUPPORT_DIR/CodexMiniLifecycle" "$AGENT_PLIST"
plutil -insert ProgramArguments.1 -string '--mini-app' "$AGENT_PLIST"
plutil -insert ProgramArguments.2 -string "$APP_DEST" "$AGENT_PLIST"
plutil -insert RunAtLoad -bool YES "$AGENT_PLIST"
plutil -insert KeepAlive -bool YES "$AGENT_PLIST"
plutil -insert ProcessType -string Background "$AGENT_PLIST"
plutil -insert ThrottleInterval -integer 10 "$AGENT_PLIST"
plutil -insert StandardOutPath -string "$SUPPORT_DIR/lifecycle.log" "$AGENT_PLIST"
plutil -insert StandardErrorPath -string "$SUPPORT_DIR/lifecycle-error.log" "$AGENT_PLIST"
chmod 644 "$AGENT_PLIST"
launchctl bootstrap "gui/$UID" "$AGENT_PLIST"
echo "已设置：本机 Codex 启动时自动打开看板；退出 Codex 后关闭。"
