#!/bin/zsh
set -eu
AGENT_LABEL="local.dean.CodexMini.lifecycle"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
if launchctl print "gui/$UID/$AGENT_LABEL" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID/$AGENT_LABEL"
fi
if [[ -f "$AGENT_PLIST" ]]; then rm "$AGENT_PLIST"; fi
echo "已取消联动。看板应用仍保留，可手动启动。"
