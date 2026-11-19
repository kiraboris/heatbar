#!/bin/bash
# Removes HeatBar, its launch agent and its settings. The log stays in ~/Library/Logs/HeatBar.log.
shopt -s nocaseglob
APP="$HOME/Applications/HeatBar.app"
LABEL="$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)"
for plist in "$HOME"/Library/LaunchAgents/*heatbar*.plist; do
  [ -e "$plist" ] || continue
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null
  rm -f "$plist"
done
pkill -x HeatBar 2>/dev/null
rm -rf "$APP"
[ -n "$LABEL" ] && defaults delete "$LABEL" 2>/dev/null
echo "HeatBar removed."
