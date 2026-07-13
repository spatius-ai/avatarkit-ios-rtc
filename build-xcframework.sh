#!/bin/bash
# Build distributable XCFrameworks for AvatarKitRTC + AvatarKitAgoraBridge,
# matching the structure of the prior AvatarKit-iOS-RTC delivery zip.
#
# Both modules are static frameworks. Third-party deps (Agora, AvatarKit binary,
# SwiftProtobuf) are NOT embedded — they are compiled for symbol resolution only;
# the integrator supplies them (see 集成说明.md §四).
#
# Output: dist/<Module>.xcframework  (ios-arm64 device + ios-arm64 simulator)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/AvatarKitRTC"
BUILD="$ROOT/build"
OUT="$ROOT/dist"
SCHEME="AvatarKitRTC"          # builds AvatarKitRTC + its dep AvatarKitAgoraBridge

MODULES=("AvatarKitRTC" "AvatarKitAgoraBridge")

rm -rf "$BUILD" "$OUT"
mkdir -p "$BUILD" "$OUT"

# ---------------------------------------------------------------------------
# 1. Archive the scheme for device + simulator. SPM targets compile to
#    <Module>.o + <Module>.swiftmodule (+ generated modulemap/headers), not
#    framework bundles — so we archive, then assemble the bundles by hand.
# ---------------------------------------------------------------------------
archive() {                    # $1 = destination, $2 = tag (device|sim)
  local dest="$1" tag="$2"
  echo "==> Archiving ($tag): $dest"
  # The Agora / AvatarKit binary deps ship arm64-only slices, so the simulator
  # build must exclude x86_64 (Intel Mac simulator is unsupported — see §五).
  ( cd "$PKG" && xcodebuild archive \
      -scheme "$SCHEME" \
      -destination "$dest" \
      -archivePath "$BUILD/$tag.xcarchive" \
      -derivedDataPath "$BUILD/dd-$tag" \
      SKIP_INSTALL=NO \
      BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
      ONLY_ACTIVE_ARCH=NO \
      ARCHS=arm64 >/dev/null )
}

archive "generic/platform=iOS"           device
archive "generic/platform=iOS Simulator" sim

# ---------------------------------------------------------------------------
# 2. Assemble a static <Module>.framework from the archive products.
# ---------------------------------------------------------------------------
assemble_framework() {         # $1 = module, $2 = tag, $3 = out framework dir
  local module="$1" tag="$2" fw="$3"
  local base="$BUILD/dd-$tag/Build/Intermediates.noindex/ArchiveIntermediates/$SCHEME"
  local sdk; [ "$tag" = "device" ] && sdk="iphoneos" || sdk="iphonesimulator"
  local pdir="$base/BuildProductsPath/Release-$sdk"
  local gdir="$base/IntermediateBuildFilesPath/GeneratedModuleMaps-$sdk"
  # The .o under BuildProductsPath is a symlink into a cleaned-up install dir;
  # the real Mach-O object lives in the archive's Products tree.
  local objdir="$BUILD/$tag.xcarchive/Products/Users/$(whoami)/Objects"

  rm -rf "$fw"
  mkdir -p "$fw/Headers" "$fw/Modules"

  # Static binary: the object file IS the static framework binary.
  cp "$objdir/$module.o" "$fw/$module"

  # Swift module (Swift targets only).
  if [ -e "$pdir/$module.swiftmodule" ]; then
    mkdir -p "$fw/Modules/$module.swiftmodule"
    cp -R "$pdir/$module.swiftmodule/." "$fw/Modules/$module.swiftmodule/"
  fi

  # Generated -Swift.h / umbrella / modulemap.
  [ -e "$gdir/$module-Swift.h" ] && cp "$gdir/$module-Swift.h" "$fw/Headers/"
  # Umbrella header: reuse the source public header for the ObjC bridge; the
  # Swift module has an auto-generated umbrella.
  if [ "$module" = "AvatarKitAgoraBridge" ]; then
    cp "$PKG/Sources/AvatarKitAgoraBridge/include/"*.h "$fw/Headers/" 2>/dev/null || true
  fi

  # module.modulemap (patched to framework form).
  write_modulemap "$module" "$fw/Modules/module.modulemap"

  # Info.plist
  write_info_plist "$module" "$fw/Info.plist"
}

write_modulemap() {            # $1 = module, $2 = out path
  local module="$1" out="$2"
  if [ "$module" = "AvatarKitRTC" ]; then
    cat > "$out" <<EOF
framework module AvatarKitRTC {
  umbrella header "AvatarKitRTC-umbrella.h"

  export *
  module * { export * }
}

module AvatarKitRTC.Swift {
  header "AvatarKitRTC-Swift.h"
  requires objc
}
EOF
    # umbrella for RTC (Swift-only target has empty ObjC umbrella)
    echo "" > "$(dirname "$(dirname "$out")")/Headers/AvatarKitRTC-umbrella.h"
  else
    cat > "$out" <<EOF
framework module AvatarKitAgoraBridge {
  umbrella header "AvatarKitAgoraBridge-umbrella.h"

  export *
  module * { export * }
}
EOF
    # umbrella imports the public bridge header
    echo '#import "AvatarKitAgoraBridge.h"' > "$(dirname "$(dirname "$out")")/Headers/AvatarKitAgoraBridge-umbrella.h"
  fi
}

write_info_plist() {           # $1 = module, $2 = out path
  cat > "$2" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>ai.spatius.$1</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>MinimumOSVersion</key><string>16.0</string>
</dict>
</plist>
EOF
}

# ---------------------------------------------------------------------------
# 3. For each module: assemble device + sim frameworks, then create xcframework.
# ---------------------------------------------------------------------------
for module in "${MODULES[@]}"; do
  echo "==> Packaging $module.xcframework"
  dev_fw="$BUILD/fw-device/$module.framework"
  sim_fw="$BUILD/fw-sim/$module.framework"
  assemble_framework "$module" device "$dev_fw"
  assemble_framework "$module" sim    "$sim_fw"

  xcodebuild -create-xcframework \
    -framework "$dev_fw" \
    -framework "$sim_fw" \
    -output "$OUT/$module.xcframework" >/dev/null
done

echo "==> Done. Output:"
find "$OUT" -maxdepth 2 -name "*.framework" | sort
