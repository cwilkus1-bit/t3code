#!/usr/bin/env bash
# Builds the harness with the before/after T3SidebarTabBarView.swift and replays the report on an
# iPhone simulator with real touches: Chats -> Settings -> Chats (control), then
# Settings -> Environments -> Back -> Chats, then taps where New chat sits.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/out
APP_ID=dev.harness.compose
mkdir -p "$OUT"

{
  xcodebuild -version
  echo "sdk: $(xcrun --sdk iphonesimulator --show-sdk-version)"
  sw_vers
} | tee "$OUT/env.txt"

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
build() {
  local variant=$1
  local dir=$ROOT/build/$variant
  mkdir -p "$dir/Harness.app"
  sed '/^import ExpoModulesCore$/d' "$ROOT/harness/$variant/T3SidebarTabBarView.swift" > "$dir/T3SidebarTabBarView.swift"
  xcrun --sdk iphonesimulator swiftc -target "$ARCH-apple-ios26.0-simulator" -sdk "$SDK" \
    -module-name Harness -parse-as-library -Onone \
    "$ROOT/harness/Stubs.swift" "$ROOT/harness/App.swift" "$dir/T3SidebarTabBarView.swift" \
    -o "$dir/Harness.app/Harness" || exit 1
  cp "$ROOT/harness/Info.plist" "$dir/Harness.app/Info.plist"
  codesign --force --sign - "$dir/Harness.app" || exit 1
}
build before
build after

RUNTIME=$(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
runtimes.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
print(runtimes[-1]["identifier"])')
DEVICE_TYPE=$(xcrun simctl list devicetypes -j | python3 -c '
import json, sys
names = [d["name"] for d in json.load(sys.stdin)["devicetypes"]]
for wanted in ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16"]:
    if wanted in names:
        print(wanted); break
else:
    print([n for n in names if n.startswith("iPhone")][-1])')
echo "runtime: $RUNTIME device: $DEVICE_TYPE" | tee -a "$OUT/env.txt"
UDID=$(xcrun simctl create harness-iphone "$DEVICE_TYPE" "$RUNTIME")
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b > /dev/null
xcrun simctl ui "$UDID" appearance dark || true
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 || true
sleep 5
axe --version | tee -a "$OUT/env.txt" || true

run_scenario() {
  local variant=$1 delay=$2
  local run=$OUT/$variant-js$delay
  mkdir -p "$run"
  xcrun simctl uninstall "$UDID" "$APP_ID" > /dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$ROOT/build/$variant/Harness.app"
  local data
  data=$(xcrun simctl get_app_container "$UDID" "$APP_ID" data)
  rm -f "$data/Documents/"*

  coord() { awk -v k="$1" '$1 == k { print $2, $3 }' "$data/Documents/coords.txt"; }
  touch_at() {
    local x=$1 y=$2
    echo "touch $x $y ($3)" >> "$run/steps.txt"
    axe touch -x "$x" -y "$y" --down --up --delay 0.12 --udid "$UDID" > /dev/null 2>> "$run/axe-errors.txt"
  }
  shot() {
    xcrun simctl io "$UDID" screenshot "$run/$1.png" > /dev/null 2>&1
    echo "shot $1" >> "$run/steps.txt"
  }
  tap_tab() { touch_at $(coord "$1") "tab $1"; }
  burst() {
    local i
    for i in $(seq -w 1 "$2"); do
      xcrun simctl io "$UDID" screenshot "$run/$1-$i.png" > /dev/null 2>&1
    done
    echo "burst $1 x$2" >> "$run/steps.txt"
  }

  xcrun simctl io "$UDID" recordVideo --codec=h264 --force "$run/video.mp4" > /dev/null 2>&1 &
  local video=$!
  sleep 2
  SIMCTL_CHILD_JS_DELAY=$delay xcrun simctl launch "$UDID" "$APP_ID" > /dev/null
  sleep 4
  cp "$data/Documents/coords.txt" "$run/coords.txt" 2>/dev/null || echo "no coords" >> "$run/steps.txt"
  shot 01-chats-launch

  # Control: switching tabs without opening a Settings page.
  tap_tab settings; sleep 2; shot 02-settings
  tap_tab threads; sleep 2.5; shot 03-chats-control

  # The report: Settings > Environments, back, then Chats.
  tap_tab settings; sleep 2; shot 04-settings
  touch_at $(coord page) "Environments"; sleep 2; shot 05-environments
  touch_at $(coord page) "Back"; sleep 2; shot 06-settings-after-back
  # Screenshots from the moment the press is sent until well after JS commits.
  burst 07-chats-burst 14 &
  local shots=$!
  tap_tab threads; wait "$shots"; sleep 2; shot 07z-chats-settled
  touch_at $(coord compose) "New chat"; sleep 1.5; shot 08-after-new-chat-tap

  # Does it recover with more tab switches?
  tap_tab settings; sleep 2; tap_tab threads; sleep 2.5; shot 09-chats-again
  touch_at $(coord compose) "New chat"; sleep 1.5; shot 10-after-second-new-chat-tap

  kill -INT "$video" 2>/dev/null; wait "$video" 2>/dev/null
  xcrun simctl terminate "$UDID" "$APP_ID" > /dev/null 2>&1 || true
  cp "$data/Documents/harness.log" "$run/harness.log" 2>/dev/null || true
  echo "$variant js$delay: new chat taps = $(grep -c 'NEW CHAT TAPPED' "$run/harness.log" 2>/dev/null) (expected 2)" | tee -a "$OUT/summary.txt"
}

for delay in ${JS_DELAYS:-0.05 1.5}; do
  run_scenario before "$delay"
  run_scenario after "$delay"
done
cat "$OUT/summary.txt"
