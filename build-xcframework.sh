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
# only; the integrator supplies them at link time (see 集成说明.md §五).
#
# Requirements: cocoapods, xcodegen, a local AvatarKit.xcframework pod.
#
# Usage:
#   AVATARKIT_POD_PATH=/path/to/localpath_avatarkit \   # dir with AvatarKit.podspec + AvatarKit.xcframework
#   AGORA_VERSION=4.5.2 \                                 # Agora pod version to compile against
#   ./build-xcframework.sh
#
# Output: dist/<Module>.xcframework  (ios-arm64 device + ios-arm64 simulator)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/AvatarKitRTC"                 # the SPM package dir (holds the podspecs)
OUT="$ROOT/dist"
WORK="$(mktemp -d)/pack"                 # throwaway CocoaPods project
AGORA_VERSION="${AGORA_VERSION:-4.5.2}"
AVATARKIT_POD_PATH="${AVATARKIT_POD_PATH:-}"

MODULES=("AvatarKitAgoraBridge" "AvatarKitRTC")

if [ -z "$AVATARKIT_POD_PATH" ] || [ ! -f "$AVATARKIT_POD_PATH/AvatarKit.podspec" ]; then
  echo "ERROR: set AVATARKIT_POD_PATH to a dir containing AvatarKit.podspec + AvatarKit.xcframework" >&2
  echo "  (the vendored main-SDK pod; grab AvatarKit.xcframework from the ios-release GitHub Release)" >&2
  exit 1
fi

command -v pod       >/dev/null || { echo "ERROR: cocoapods not installed" >&2; exit 1; }
command -v xcodegen  >/dev/null || { echo "ERROR: xcodegen not installed"  >&2; exit 1; }

echo "==> Agora version : $AGORA_VERSION"
echo "==> AvatarKit pod  : $AVATARKIT_POD_PATH"
echo "==> Package        : $PKG"

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
# 2. Generate a minimal host app + Podfile that pulls the three local pods and
#    the requested Agora version, then pod install.
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
  pod 'AvatarKit',            :path => '$AVATARKIT_POD_PATH'
  pod 'AvatarKitAgoraBridge', :path => '$STAGE'
  pod 'AvatarKitRTC',         :path => '$STAGE'
  pod 'AgoraRtcEngine_iOS',   '$AGORA_VERSION'
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

echo "==> Done. Output in $OUT:"
ls -d "$OUT"/*.xcframework
echo
echo "NOTE: AvatarKit.xcframework (main SDK) is shipped as-is from the ios-release"
echo "      GitHub Release; add it to the delivery zip alongside these two."
