#!/bin/bash
# Build distributable XCFrameworks for AvatarKitRTC + AvatarKitAgoraBridge.
#
# Approach: drive CocoaPods to compile the SPM-style sources into real
# .framework bundles (with swiftmodule + generated headers), then combine the
# device + simulator slices with `xcodebuild -create-xcframework`. This is more
# robust than hand-assembling framework bundles from `xcodebuild archive`
# products (which produce .o + loose swiftmodule, easy to get wrong).
#
# Both modules are STATIC frameworks. Third-party deps (Agora, AvatarKit binary,
# SwiftProtobuf) are NOT embedded — they are compiled for symbol resolution
# only; the integrator supplies them at link time.
#
# Requirements: cocoapods, xcodegen.
#
# Usage:
#   ./build-xcframework.sh
#
# Every dependency comes from the podspecs as committed — the release version,
# SpatiusAvatarKit (from the avatarkit-specs spec repo) and the Agora pod. On an Agora special-build
# branch (release-process.md §9) the podspecs name AgoraRtcEngine_Special_iOS,
# so the same script compiles against the special SDK with no extra input.
#
# Output: dist/<Module>.xcframework  (ios-arm64 device + ios-arm64 simulator)
#         dist/AvatarKitRTC-<version>-xcframeworks.zip  (both + DEPENDENCIES.txt + LICENSE)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/AvatarKitRTC"                 # the SPM package dir (holds the podspecs)
OUT="$ROOT/dist"
WORK="$(mktemp -d)/pack"                 # throwaway CocoaPods project
MODULES=("AvatarKitAgoraBridge" "AvatarKitRTC")

command -v pod       >/dev/null || { echo "ERROR: cocoapods not installed" >&2; exit 1; }
command -v xcodegen  >/dev/null || { echo "ERROR: xcodegen not installed"  >&2; exit 1; }

# Read what the podspecs pin; they are the single source for all of it.
podspec_value() {   # $1 = podspec, $2 = sed -E expression printing the value
  sed -nE "$2" "$PKG/$1" | head -1
}
VERSION="$(podspec_value AvatarKitRTC.podspec 's/^[[:space:]]*spec\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p')"
AGORA_POD="$(podspec_value AvatarKitAgoraBridge.podspec 's/^[[:space:]]*spec\.dependency[[:space:]]+"(AgoraRtcEngine[A-Za-z_]*)".*/\1/p')"
AGORA_VERSION="$(podspec_value AvatarKitAgoraBridge.podspec 's/^[[:space:]]*spec\.dependency[[:space:]]+"AgoraRtcEngine[A-Za-z_]*",[[:space:]]*"([^"]+)".*/\1/p')"
AVATARKIT_VERSION="$(podspec_value AvatarKitRTC.podspec 's/^[[:space:]]*spec\.dependency[[:space:]]+"SpatiusAvatarKit",[[:space:]]*"([^"]+)".*/\1/p')"
PROTOBUF_VERSION="$(podspec_value AvatarKitRTC.podspec 's/^[[:space:]]*spec\.dependency[[:space:]]+"SwiftProtobuf",[[:space:]]*"([^"]+)".*/\1/p')"
MIN_IOS="$(podspec_value AvatarKitRTC.podspec 's/^[[:space:]]*spec\.platform[[:space:]]*=[[:space:]]*:ios,[[:space:]]*"([^"]+)".*/\1/p')"
for v in VERSION AGORA_POD AGORA_VERSION AVATARKIT_VERSION PROTOBUF_VERSION MIN_IOS; do
  [ -n "${!v}" ] || { echo "ERROR: could not read $v from the podspecs" >&2; exit 1; }
done

echo "==> Version   : $VERSION"
echo "==> Agora     : $AGORA_POD $AGORA_VERSION"
echo "==> AvatarKit : SpatiusAvatarKit $AVATARKIT_VERSION"
echo "==> Package   : $PKG"

# ---------------------------------------------------------------------------
# 1. Stage a copy of the package with podspec source_files rewritten for local
#    :path use (the committed podspecs prefix paths with AvatarKitRTC/ for the
#    :git remote checkout; a local :path points straight at the package dir).
# ---------------------------------------------------------------------------
STAGE="$(dirname "$WORK")/pkg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$PKG/." "$STAGE/"
cp "$ROOT/LICENSE" "$STAGE/LICENSE"
sed -i '' 's|"AvatarKitRTC/Sources/|"Sources/|g' "$STAGE/AvatarKitRTC.podspec" "$STAGE/AvatarKitAgoraBridge.podspec"

# ---------------------------------------------------------------------------
# 2. Generate a minimal host app + Podfile that pulls the two local pods; their
#    podspecs bring SpatiusAvatarKit, SwiftProtobuf and the Agora pod.
# ---------------------------------------------------------------------------
mkdir -p "$WORK/App"
cat > "$WORK/App/App.swift" <<'SWIFT'
import SwiftUI
@main struct PackApp: App { var body: some Scene { WindowGroup { Text("pack") } } }
SWIFT
cat > "$WORK/project.yml" <<YML
name: Pack
options: { bundleIdPrefix: ai.spatius.pack, deploymentTarget: { iOS: "$MIN_IOS" } }
targets:
  Pack:
    type: application
    platform: iOS
    sources: [App]
    settings: { base: { GENERATE_INFOPLIST_FILE: YES, PRODUCT_BUNDLE_IDENTIFIER: ai.spatius.pack, SWIFT_VERSION: "6.0" } }
YML
# SpatiusAvatarKit (and both RTC pods) live in our spec repo — CocoaPods trunk is
# read-only from 2026-12-02; Agora / SwiftProtobuf still come from the CDN.
cat > "$WORK/Podfile" <<RUBY
source 'https://github.com/spatius-ai/avatarkit-specs.git'
source 'https://cdn.cocoapods.org/'
platform :ios, '$MIN_IOS'
