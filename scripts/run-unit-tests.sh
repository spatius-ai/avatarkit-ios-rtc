#!/usr/bin/env bash
#
# Runs the SPM unit tests (AvatarKitRTC/Tests/AvatarKitRTCTests) on an iOS
# simulator.
#
# A plain `xcodebuild test` builds, but the test bundle then refuses to load:
# "Library not loaded: @rpath/AgoraRtcKit.framework … Trying to load an
# unsigned library" — the binary frameworks copied next to the bundle are
# unsigned. So this builds for testing, signs those frameworks ad hoc, and runs
# the already-built bundle.
#
# `swift test` is not an option either: it targets macOS, and Agora ships iOS
# binaries only.
#
# Usage: scripts/run-unit-tests.sh
#   SIMULATOR_ID=<udid>   use this simulator instead of picking one
#   KEEP_DERIVED_DATA=1   keep the temporary derived-data directory
#
# Exit code: 0 when every test passed, non-zero otherwise.

set -euo pipefail

cd "$(dirname "$0")/.."

source scripts/lib/simulator.sh

if ! picked="$(pick_simulator)"; then
    echo "FAIL unit-tests: no available iPhone simulator (xcrun simctl list devices)"
    exit 1
fi
sim_id="${picked%% *}"
sim_desc="${picked#* }"

tmp_root="${TMPDIR:-/tmp}"
derived="$(mktemp -d "${tmp_root%/}/avatarkit-rtc-unit.XXXXXX")"
log="$derived/xcodebuild.log"
if [[ "${KEEP_DERIVED_DATA:-0}" != "1" ]]; then
    trap 'rm -rf "$derived"' EXIT
fi

destination="platform=iOS Simulator,id=$sim_id"
echo "Simulator:    $sim_desc ($sim_id)"
echo "Derived data: $derived"

echo "==> build-for-testing"
if ! xcodebuild build-for-testing -scheme AvatarKitRTC -destination "$destination" \
        -derivedDataPath "$derived" >"$log" 2>&1; then
    grep -E "error:" "$log" | head -20 || true
    echo "FAIL unit-tests: build-for-testing failed (log: $log)"
    trap - EXIT
    exit 1
fi

echo "==> ad-hoc signing binary frameworks"
find "$derived/Build/Products/Debug-iphonesimulator" -maxdepth 3 -name '*.framework' \
    -exec codesign --force --deep --sign - {} \; 2>/dev/null

echo "==> test-without-building"
status=0
xcodebuild test-without-building -scheme AvatarKitRTC -destination "$destination" \
    -derivedDataPath "$derived" >"$log" 2>&1 || status=$?

# XCTest occasionally gives up launching the runner on a busy machine before
# any test runs ("Timed out while preparing execution worker"). That is the
# simulator, not the tests — retry once.
if [[ $status -ne 0 ]] && grep -q "Timed out while preparing execution worker" "$log"; then
    echo "==> test runner failed to start (simulator timeout); retrying once"
    status=0
    xcodebuild test-without-building -scheme AvatarKitRTC -destination "$destination" \
        -derivedDataPath "$derived" >"$log" 2>&1 || status=$?
fi

# The last "Executed N tests, with M failures" line is the all-tests total.
summary="$(grep -E "Executed [0-9]+ tests?, with [0-9]+ failures?" "$log" | tail -1 || true)"
executed="$(sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p' <<<"$summary")"
failures="$(sed -nE 's/.*with ([0-9]+) failures?.*/\1/p' <<<"$summary")"

grep -E "error: -\[|Test Case .* failed" "$log" | head -20 || true

if [[ $status -ne 0 || -z "$executed" || "$failures" != "0" || "$executed" == "0" ]]; then
    echo "FAIL unit-tests: executed=${executed:-?} failed=${failures:-?} (xcodebuild exit $status, log: $log)"
    trap - EXIT
    exit 1
fi

echo "PASS unit-tests: executed=$executed failed=$failures ($sim_desc)"
