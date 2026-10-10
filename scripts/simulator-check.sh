#!/bin/bash
# Builds Shelf for the iPhone simulator, checks article extraction against live sites,
# and takes screenshots of the main screens in light and dark mode.
set -eo pipefail

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
c=[x for r,l in d.items() if "iOS" in r for x in l if x["name"].startswith("iPhone") and "Pro" in x["name"] and "Max" not in x["name"]]
c.sort(key=lambda x:x["name"])
print(c[-1]["udid"])')
echo "Using simulator $UDID"

xcodebuild -project Shelf.xcodeproj -scheme Shelf -configuration Debug -sdk iphonesimulator \
  -destination "id=$UDID" -derivedDataPath build CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build.log | grep -E "error:|warning: unre|BUILD (SUCCEEDED|FAILED)" || true
grep -q "BUILD SUCCEEDED" build.log || { echo "::error::Build failed"; grep -E "error:" build.log | head -50; exit 1; }

APP=build/Build/Products/Debug-iphonesimulator/Shelf.app
BID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Info.plist")

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 || true
xcrun simctl install "$UDID" "$APP"
mkdir -p shots

# 1. Live extraction check on real pages.
xcrun simctl launch --terminate-running-process "$UDID" "$BID" -ShelfSelfTest
for i in $(seq 1 60); do
  DATA=$(xcrun simctl get_app_container "$UDID" "$BID" data)
  [ -f "$DATA/Documents/selftest.json" ] && break
  sleep 2
done
if [ -f "$DATA/Documents/selftest.json" ]; then
  cp "$DATA/Documents/selftest.json" shots/selftest.json
  python3 -m json.tool shots/selftest.json
else
  echo "::warning::Self-test produced no result"
fi
xcrun simctl terminate "$UDID" "$BID" || true

# 2. Screenshots with sample content.
shoot() { # name, extra args
  local name=$1; shift
  xcrun simctl launch --terminate-running-process "$UDID" "$BID" -ShelfDemo "$@"
  sleep 5
  xcrun simctl io "$UDID" screenshot "shots/$name.png"
}
for mode in light dark; do
  xcrun simctl ui "$UDID" appearance $mode
  shoot "saved-$mode"
  shoot "reader-$mode" -ShelfDemoReader
  shoot "foryou-$mode" -ShelfDemoForYou
done
ls -la shots
