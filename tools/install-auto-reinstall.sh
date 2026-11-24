#!/bin/bash
# Installs (or removes with --remove) the launchd agent that runs tools/reinstall.sh every hour and at login.
# Run once on your Mac, from the repository: ./tools/install-auto-reinstall.sh
set -euo pipefail
LABEL="io.github.healthhook.reinstall"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/reinstall.sh"
STATE="$HOME/Library/Application Support/HealthHook"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ "${1:-}" = "--remove" ]; then
  rm -f "$PLIST"; echo "Agent removed."; exit 0
fi

command -v xcodegen >/dev/null || { echo "Install xcodegen first: brew install xcodegen"; exit 1; }
chmod +x "$SCRIPT"
mkdir -p "$HOME/Library/LaunchAgents" "$STATE"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SCRIPT</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$STATE/launchd.log</string>
  <key>StandardErrorPath</key><string>$STATE/launchd.log</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Agent installed: $LABEL (every hour)."
echo "Reinstalls when the app expires in less than 2 days. Log: $STATE/reinstall.log"
