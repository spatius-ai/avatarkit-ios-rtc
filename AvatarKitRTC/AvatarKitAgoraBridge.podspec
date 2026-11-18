Pod::Spec.new do |spec|
  spec.name         = "AvatarKitAgoraBridge"
  spec.version      = "1.2.0-agora-special-compat-ios13"
  spec.summary      = "ObjC++ bridge exposing Agora's encoded-frame observer to Swift"
  spec.description  = <<-DESC
                      Wraps Agora's C++ IVideoEncodedFrameObserver into a Swift-callable
                      block. Kept as a standalone pod so it compiles as its own Clang
                      module (`import AvatarKitAgoraBridge`), matching the SPM target layout.
                      DESC
  spec.homepage     = "https://github.com/spatius-ai/avatarkit-ios-rtc"
  spec.license      = {
    :type => "Proprietary",
    :file => "LICENSE"
  }
  spec.author       = { "Spatius" => "hello@spatialwalk.net" }
  spec.platform     = :ios, "13.0"
  spec.source       = { :git => "https://github.com/spatius-ai/avatarkit-ios-rtc.git", :tag => "v#{spec.version}" }

  # Paths are relative to the repo root (what `:git` checks out), so they
  # include the `AvatarKitRTC/` package subdirectory prefix.
  spec.source_files        = "AvatarKitRTC/Sources/AvatarKitAgoraBridge/**/*.{h,mm}"
  spec.public_header_files  = "AvatarKitRTC/Sources/AvatarKitAgoraBridge/include/*.h"
  spec.requires_arc         = true
  # Allow the customer special SDK 4.5.x line, including prerelease versions.
  # 4.5.3.3.BASIC is the tested baseline; the integrator selects the resolved version.
  spec.dependency "AgoraRtcEngine_Special_iOS", "~> 4.5.0.BASIC"
  spec.pod_target_xcconfig  = {
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++17",
    "CLANG_CXX_LIBRARY"           => "libc++"
  }
end
