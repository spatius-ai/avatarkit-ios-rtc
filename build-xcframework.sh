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
# SpatiusAvatarKit (from trunk) and the Agora pod. On an Agora special-build
# branch (release-process.md §9) the podspecs name AgoraRtcEngine_Special_iOS,
# so the same script compiles against the special SDK with no extra input.
#
# Output: dist/<Module>.xcframework  (ios-arm64 device + ios-arm64 simulator)
#         dist/AvatarKitRTC-<version>-xcframeworks.zip  (both + DEPENDENCIES.txt)
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
for v in VERSION AGORA_POD AGORA_VERSION AVATARKIT_VERSION PROTOBUF_VERSION; do
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
options: { bundleIdPrefix: ai.spatius.pack, deploymentTarget: { iOS: "16.0" } }
targets:
  Pack:
    type: application
    platform: iOS
    sources: [App]
    settings: { base: { GENERATE_INFOPLIST_FILE: YES, PRODUCT_BUNDLE_IDENTIFIER: ai.spatius.pack, SWIFT_VERSION: "6.0" } }
YML
cat > "$WORK/Podfile" <<RUBY
platform :ios, '16.0'
install! 'cocoapods', :warn_for_unused_master_specs_repo => false
target 'Pack' do
  use_frameworks! :linkage => :static
  pod 'AvatarKitAgoraBridge', :path => '$STAGE'
  pod 'AvatarKitRTC',         :path => '$STAGE'
end
post_install do |i|
  i.pods_project.targets.each { |t| t.build_configurations.each { |c| c.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'x86_64' } }
end
RUBY

( cd "$WORK" && xcodegen generate >/dev/null && pod install >/dev/null )

# ---------------------------------------------------------------------------
# 3. Build each pod scheme for device + simulator (Release, distribution),
#    then create the xcframework from the two produced .framework bundles.
# ---------------------------------------------------------------------------
build() {   # $1 = scheme, $2 = sdk, $3 = destination, $4 = derivedData
  ( cd "$WORK" && xcodebuild build \
      -workspace Pack.xcworkspace -scheme "$1" \
      -sdk "$2" -destination "$3" -configuration Release \
      ARCHS=arm64 EXCLUDED_ARCHS=x86_64 \
      BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
      -derivedDataPath "$4" >/dev/null )
}

rm -rf "$OUT"; mkdir -p "$OUT"
for module in "${MODULES[@]}"; do
  echo "==> Building $module (device + simulator)"
  build "$module" iphoneos        'generic/platform=iOS'           "$WORK/dd-dev"
  build "$module" iphonesimulator 'generic/platform=iOS Simulator' "$WORK/dd-sim"

  dev="$(find "$WORK/dd-dev/Build/Products" -name "$module.framework" -type d | grep -v XCFramework | head -1)"
  sim="$(find "$WORK/dd-sim/Build/Products" -name "$module.framework" -type d | grep -v XCFramework | head -1)"
  [ -n "$dev" ] && [ -n "$sim" ] || { echo "ERROR: $module.framework not produced" >&2; exit 1; }

  echo "==> Packaging $module.xcframework"
  xcodebuild -create-xcframework -framework "$dev" -framework "$sim" \
    -output "$OUT/$module.xcframework" >/dev/null
done

# 4. Zip both with a note of what the integrator must supply.
cat > "$OUT/DEPENDENCIES.txt" <<TXT
AvatarKitRTC $VERSION — offline XCFrameworks (AvatarKitRTC + AvatarKitAgoraBridge)

Static frameworks; nothing third-party is embedded. The app must also link:
  - AvatarKit (main SDK) $AVATARKIT_VERSION (CocoaPods: SpatiusAvatarKit $AVATARKIT_VERSION)
  - Agora: $AGORA_POD $AGORA_VERSION — exactly this pod and version
  - SwiftProtobuf $PROTOBUF_VERSION
iOS 16.0+, arm64 device and arm64 simulator.
TXT
ZIP="$OUT/AvatarKitRTC-$VERSION-xcframeworks.zip"
( cd "$OUT" && zip -qry "$(basename "$ZIP")" AvatarKitAgoraBridge.xcframework AvatarKitRTC.xcframework DEPENDENCIES.txt )

echo "==> Done. Output in $OUT:"
ls -d "$OUT"/*.xcframework "$ZIP"
