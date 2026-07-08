Pod::Spec.new do |spec|
  spec.name         = "AvatarKitAgoraBridge"
  spec.version      = "1.0.0-beta.5"
  spec.summary      = "ObjC++ bridge exposing Agora's encoded-frame observer to Swift"
  spec.description  = <<-DESC
                      Wraps Agora's C++ IVideoEncodedFrameObserver into a Swift-callable
                      block. Kept as a standalone pod so it compiles as its own Clang
                      module (`import AvatarKitAgoraBridge`), matching the SPM target layout.
                      DESC
  spec.homepage     = "https://github.com/spatius-ai/avatarkit-ios-rtc"
  spec.license      = { :type => "Commercial" }
  spec.author       = { "Spatius" => "hello@spatialwalk.net" }
  spec.platform     = :ios, "16.0"
  spec.source       = { :git => "https://github.com/spatius-ai/avatarkit-ios-rtc.git", :tag => "v#{spec.version}" }

  spec.source_files        = "Sources/AvatarKitAgoraBridge/**/*.{h,mm}"
  spec.public_header_files  = "Sources/AvatarKitAgoraBridge/include/*.h"
  spec.requires_arc         = true
  spec.dependency "AgoraRtcEngine_iOS", "4.6.2"
  spec.pod_target_xcconfig  = {
    "CLANG_CXX_LANGUAGE_STANDARD" => "c++17",
    "CLANG_CXX_LIBRARY"           => "libc++"
  }
end
