#!/bin/bash
# Installs HeatBar to ~/Applications and starts it at login.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/HeatBar.app"
[ -d HeatBar.app ] || { echo "HeatBar.app not found next to install.sh"; exit 1; }
LABEL="$(defaults read "$(pwd)/HeatBar.app/Contents/Info" CFBundleIdentifier)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

shopt -s nocaseglob
# Stop a running copy: this label, an older install under another label, or one started by hand
for old in "$HOME"/Library/LaunchAgents/*heatbar*.plist; do
  [ -e "$old" ] || continue
  launchctl bootout "gui/$(id -u)" "$old" 2>/dev/null || true
  [ "$old" = "$PLIST" ] || rm -f "$old"
done
pkill -x HeatBar 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x HeatBar >/dev/null || break; sleep 0.5; done

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
ditto HeatBar.app "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

# Plain launch at login. Restarts after a crash, but "Quit HeatBar" stays quit until next login.
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
 <key>Label</key><string>$LABEL</string>
 <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/HeatBar</string></array>
 <key>RunAtLoad</key><true/>
 <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
 <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PL
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "HeatBar $(defaults read "$APP/Contents/Info" CFBundleShortVersionString) installed and running. Look for 🖥 in the menu bar."
