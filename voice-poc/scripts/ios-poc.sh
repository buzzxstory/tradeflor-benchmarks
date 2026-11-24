#!/usr/bin/env bash
# iOS compatibility PoC: stasel WebRTC 125.0.0 + LiveKit Swift 2.19.0 in one app. Produces $OUT/poc-ios.md.
# Artifacts contain measurements and logs only; no app binaries leave the runner.
set -uo pipefail
POC=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$PWD/poc-ios-out}
mkdir -p "$OUT/raw"
RAW=$OUT/raw
MD=$OUT/poc-ios.md
DD=$RUNNER_TEMP/dd
SPM=$RUNNER_TEMP/spm
r() { echo "$*" >> "$MD"; }

{
  echo "# Group voice PoC: iOS SDK compatibility (GitHub macOS runner, simulator + unsigned device build)"
  echo
  echo "Runner: $(sw_vers -productName) $(sw_vers -productVersion), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) cores"
  echo "Xcode: $(xcodebuild -version | tr '\n' ' ')"
  echo
} > "$MD"

cd "$POC"
brew install xcodegen >/dev/null 2>&1 || true
xcodegen generate > "$RAW/xcodegen.log" 2>&1 || { r "xcodegen FAILED"; cat "$RAW/xcodegen.log"; exit 1; }
xcodebuild -resolvePackageDependencies -project PoCVoice.xcodeproj -scheme PoCVoice -clonedSourcePackagesDirPath "$SPM" > "$RAW/resolve.log" 2>&1
r "## Resolved packages (Package.resolved)"; r '```'
find PoCVoice.xcodeproj -name Package.resolved -exec cat {} \; | python3 -c 'import json,sys; d=json.load(sys.stdin); [print(p["identity"], p["state"].get("version"), p["state"].get("revision")) for p in d["pins"]]' >> "$MD" 2>&1
r '```'

# ---------- simulator: build-for-testing, run tests, capture "implemented in both" ----------
UDID=$(xcrun simctl list devices available -j | jq -r '[.devices | to_entries[] | select(.key | test("iOS")) | .value[] | select(.name | test("^iPhone [0-9]+( Pro)?$"))] | last | .udid')
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b > /dev/null 2>&1
r ""; r "Simulator: $(xcrun simctl list devices -j | jq -r --arg u "$UDID" '.devices | to_entries[] | .key as $k | .value[] | select(.udid==$u) | .name + " (" + $k + ")"')"

set -o pipefail
xcodebuild build-for-testing -project PoCVoice.xcodeproj -scheme PoCVoice -destination "id=$UDID" \
  -derivedDataPath "$DD/sim" -clonedSourcePackagesDirPath "$SPM" > "$RAW/sim-build.log" 2>&1
SIM_BUILD=$?
r ""; r "## Simulator build: $([ $SIM_BUILD = 0 ] && echo SUCCEEDED || echo FAILED)"
if [ $SIM_BUILD != 0 ]; then grep -E 'error:' "$RAW/sim-build.log" | head -30 | sed 's/^/    /' >> "$MD"; fi

APP=$(find "$DD/sim/Build/Products" -maxdepth 2 -name PoCVoice.app | head -1)
if [ -n "$APP" ]; then
  xcrun simctl install "$UDID" "$APP"
  xcrun simctl privacy "$UDID" grant microphone com.example.poc.voice 2>&1 | tee -a "$RAW/privacy.log"
fi

# simulator unified log for duplicate-class warnings during the whole test run
xcrun simctl spawn "$UDID" log stream --level debug --style compact \
  --predicate 'eventMessage CONTAINS "implemented in both" OR eventMessage CONTAINS "One of the two will be used"' \
  > "$RAW/sim-objc-dup-log.txt" 2>&1 & LOGPID=$!

# plain app launch, stdout/stderr to file (objc prints the duplicate warning to stderr at load)
xcrun simctl launch --console-pty --terminate-running-process "$UDID" com.example.poc.voice > "$RAW/app-launch-console.txt" 2>&1 & LP=$!
sleep 15; kill $LP 2>/dev/null; xcrun simctl terminate "$UDID" com.example.poc.voice 2>/dev/null

TEST_RUNNER_POC_LK_URL=${POC_LK_URL:-} xcodebuild test-without-building -project PoCVoice.xcodeproj -scheme PoCVoice \
  -destination "id=$UDID" -derivedDataPath "$DD/sim" -clonedSourcePackagesDirPath "$SPM" \
  -resultBundlePath "$RUNNER_TEMP/poc.xcresult" > "$RAW/test.log" 2>&1
TEST_RC=$?
sleep 2; kill $LOGPID 2>/dev/null
r ""; r "## Unit tests (simulator): exit $TEST_RC"
r '```'
grep -E "Test Case .*(passed|failed|skipped)|POC_RESULT" "$RAW/test.log" | sed -E 's/^.*(POC_RESULT)/\1/' | awk '!seen[$0]++' >> "$MD"
r '```'
xcrun xcresulttool get test-results summary --path "$RUNNER_TEMP/poc.xcresult" > "$RAW/xcresult-summary.json" 2>/dev/null || true
DUPS_TEST=$(grep -c "implemented in both" "$RAW/test.log")
DUPS_LOG=$(grep -c "implemented in both" "$RAW/sim-objc-dup-log.txt")
DUPS_LAUNCH=$(grep -c "implemented in both" "$RAW/app-launch-console.txt")
r ""; r "## \"Class X is implemented in both\" warnings"
r "- xcodebuild test log: $DUPS_TEST lines"
r "- simulator unified log (log stream during tests): $DUPS_LOG lines"
r "- app launch console (stderr, 15 s): $DUPS_LAUNCH lines"
if [ $((DUPS_TEST + DUPS_LOG + DUPS_LAUNCH)) -gt 0 ]; then
  r '```'; grep -h "implemented in both" "$RAW/test.log" "$RAW/sim-objc-dup-log.txt" "$RAW/app-launch-console.txt" | sed -E 's#/Users/[^ ]*/#.../#g' | sort -u | head -20 >> "$MD"; r '```'
fi

# ---------- device Release builds (unsigned) for sizes and symbols; binaries never uploaded ----------
for S in PoCVoice PoCVoiceNoLK; do
  xcodebuild build -project PoCVoice.xcodeproj -scheme "$S" -configuration Release -destination generic/platform=iOS \
    -derivedDataPath "$DD/dev-$S" -clonedSourcePackagesDirPath "$SPM" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
    > "$RAW/device-build-$S.log" 2>&1
  r ""; r "## Device Release build $S: $([ $? = 0 ] && echo SUCCEEDED || echo FAILED)"
done
A=$(find "$DD/dev-PoCVoice/Build/Products/Release-iphoneos" -maxdepth 1 -name PoCVoice.app | head -1)
B=$(find "$DD/dev-PoCVoiceNoLK/Build/Products/Release-iphoneos" -maxdepth 1 -name PoCVoiceNoLK.app | head -1)
kb() { du -sk "$1" 2>/dev/null | cut -f1; }
zkb() { local z="$RUNNER_TEMP/z-$RANDOM.zip"; (cd "$(dirname "$1")" && zip -qry "$z" "$(basename "$1")"); echo $(( $(stat -f %z "$z") / 1024 )); rm -f "$z"; }
if [ -n "$A" ] && [ -n "$B" ]; then
  r ""; r "## Sizes (device arm64, Release, unsigned; KiB on disk / zip-compressed as a rough download proxy)"
  r ""; r "| item | with LiveKit | without LiveKit |"; r "|---|---|---|"
  r "| whole .app | $(kb "$A") / $(zkb "$A") | $(kb "$B") / $(zkb "$B") |"
  r "| main executable (LiveKit Swift module is linked statically here) | $(( $(stat -f %z "$A/PoCVoice") / 1024 )) | $(( $(stat -f %z "$B/PoCVoiceNoLK") / 1024 )) |"
  for fw in "$A"/Frameworks/*.framework; do
    n=$(basename "$fw"); r "| Frameworks/$n | $(kb "$fw") / $(zkb "$fw") | $( [ -d "$B/Frameworks/$n" ] && echo "$(kb "$B/Frameworks/$n") / $(zkb "$B/Frameworks/$n")" || echo '-') |"
  done
  r ""; r "Delta of the whole .app (with - without): $(( $(kb "$A") - $(kb "$B") )) KiB on disk, $(( $(zkb "$A") - $(zkb "$B") )) KiB zipped. App Store thinning/compression differs; this is the build output."

  W="$A/Frameworks/WebRTC.framework/WebRTC"; L="$A/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC"
  if [ -f "$W" ] && [ -f "$L" ]; then
    nm -gU "$W" | awk '{print $NF}' | sort -u > "$RAW/nm-webrtc.txt"
    nm -gU "$L" | awk '{print $NF}' | sort -u > "$RAW/nm-livekitwebrtc.txt"
    comm -12 "$RAW/nm-webrtc.txt" "$RAW/nm-livekitwebrtc.txt" > "$RAW/nm-overlap.txt"
    r ""; r "## Exported symbols (nm -gU)"
    r "- WebRTC.framework: $(wc -l < "$RAW/nm-webrtc.txt") exported; LiveKitWebRTC.framework: $(wc -l < "$RAW/nm-livekitwebrtc.txt") exported"
    r "- identical exported names in both: **$(wc -l < "$RAW/nm-overlap.txt")** (ObjC class/metaclass: $(grep -c '_OBJC_' "$RAW/nm-overlap.txt"); C++ (__Z): $(grep -c '^__Z' "$RAW/nm-overlap.txt"); other C: $(grep -vc -e '_OBJC_' -e '^__Z' "$RAW/nm-overlap.txt"))"
    r "- sample of overlapping names:"; r '```'; head -25 "$RAW/nm-overlap.txt" >> "$MD"; r '```'
    r "- Mach-O flags (TWOLEVEL = two-level namespace: each import is bound to the library that provided it at link time):"
    r '```'
    for f in "$A/PoCVoice" "$W" "$L"; do echo "$(basename "$f"): $(otool -hv "$f" | tail -1 | grep -oE 'TWOLEVEL|FLAT_NAMESPACE' | sort -u | tr '\n' ' ')" >> "$MD"; done
    echo "PoCVoice links:" >> "$MD"; otool -L "$A/PoCVoice" | tail -n +2 | grep -v '/System/\|/usr/lib' >> "$MD"
    r '```'
    r "- Which framework do the app's RTC* imports bind to (dyld_info/nm of the main executable):"
    r '```'; nm -m "$A/PoCVoice" 2>/dev/null | grep -E 'undefined.*\(from (WebRTC|LiveKitWebRTC)\)' | sed -E 's/.*\(from ([A-Za-z]+)\).*/\1/' | sort | uniq -c >> "$MD"; r '```'
  else
    r "WebRTC or LiveKitWebRTC framework missing from the app bundle: $(ls "$A/Frameworks" 2>&1 | tr '\n' ' ')"
  fi
fi
r ""; r "_Results generated by ios/poc/scripts/ios-poc.sh. No binaries are uploaded._"
cat "$MD"
