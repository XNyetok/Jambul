#!/bin/zsh
# Build Jambul with Xcode and (re)launch it.
set -euo pipefail
cd "${0:A:h}/.."

export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
xcodebuild -project Jambul.xcodeproj -scheme Jambul -configuration Debug \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData -quiet build

# Between quitting the old Jambul and Keep Awake coming back on in the new one, nothing holds the display. With nobody
# at the Mac past the display's sleep time, it could dim then, so the display is held across the relaunch.
caffeinate -d -t 20 >/dev/null 2>&1 &
pkill -x Jambul 2>/dev/null || true
while pgrep -x Jambul >/dev/null; do sleep 0.1; done

# macOS can refuse to open the app right after the old one quit (error -600), though it works a moment later,
# so keep trying for a few seconds before giving up.
app=build/DerivedData/Build/Products/Debug/Jambul.app
for attempt in {1..10}; do
  if open "$app" 2>/dev/null; then exit 0; fi
  sleep 0.5
done
open "$app"
