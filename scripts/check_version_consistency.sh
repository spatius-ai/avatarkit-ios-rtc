#!/usr/bin/env bash
#
# Fails when this package's version is not identical in all three places that
# carry it. Swift Package Manager has no build-time substitution, so the
# telemetry constant cannot be derived from the podspec — it has to be written
# by hand, and it has silently drifted twice (beta.6 through the beta.7 release,
# beta.9 through 1.0.0). Nothing at runtime notices: the wrong number just
# appears on every telemetry record.
#
# Run from the repo root, or via the release process before tagging.

set -euo pipefail

cd "$(dirname "$0")/.."

fail=0

extract() {
    # $1 = file, $2 = sed expression yielding the version
    local file="$1" expr="$2" value
    if [[ ! -f "$file" ]]; then
        echo "  MISSING  $file"
        fail=1
        return
    fi
    value="$(sed -n "$expr" "$file" | head -1)"
    if [[ -z "$value" ]]; then
        echo "  UNREADABLE  $file — the version line did not match; this script"
        echo "              needs updating alongside whatever moved it."
        fail=1
        return
    fi
    echo "$value"
}

telemetry_file="AvatarKitRTC/Sources/AvatarKitRTC/Utils/TelemetryIdentity.swift"
rtc_podspec="AvatarKitRTC/AvatarKitRTC.podspec"
bridge_podspec="AvatarKitRTC/AvatarKitAgoraBridge.podspec"

telemetry="$(extract "$telemetry_file" 's/.*static let sdkVersion = "\([^"]*\)".*/\1/p')"
rtc="$(extract "$rtc_podspec" 's/.*spec\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')"
bridge="$(extract "$bridge_podspec" 's/.*spec\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p')"

[[ $fail -eq 1 ]] && exit 1

echo "TelemetryIdentity.sdkVersion    $telemetry"
echo "AvatarKitRTC.podspec            $rtc"
echo "AvatarKitAgoraBridge.podspec    $bridge"
echo

if [[ "$telemetry" == "$rtc" && "$rtc" == "$bridge" ]]; then
    echo "OK — all three agree on $telemetry"
    exit 0
fi

echo "MISMATCH — these must be identical."
echo
echo "The telemetry constant is what lands on every record this SDK emits, so a"
echo "mismatch means the data is attributed to a version that was never shipped."
echo "Update all three, then re-run:"
echo
echo "  $telemetry_file"
echo "  $rtc_podspec"
echo "  $bridge_podspec"
exit 1
