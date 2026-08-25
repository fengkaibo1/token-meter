#!/bin/bash
# 安装为登录启动项（launchd）。重复运行会先卸载旧的。
set -euo pipefail
APP="$HOME/Documents/Hermes/token-meter/token-meter"
LABEL="com.fkbo.tokenmeter"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"

mkdir -p "$AGENTS"
chmod +x "$APP"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$APP</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
</dict>
</plist>
EOF

plutil -lint "$PLIST" >/dev/null && echo ">>> plist 有效"

# 先卸载旧的，再加载（新版 launchctl）
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo ">>> 已安装并启动登录项 $LABEL"
echo "    卸载：launchctl bootout gui/$(id -u)/$LABEL"
