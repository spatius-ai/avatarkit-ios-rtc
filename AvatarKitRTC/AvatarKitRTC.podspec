Pod::Spec.new do |spec|
  spec.name         = "AvatarKitRTC"
  spec.version      = "1.0.1"
  spec.summary      = "RTC adapter for AvatarKit"
  spec.description  = <<-DESC
                      AvatarKitRTC bridges audio/animation tracks from RTC providers
                      (Agora, ...) into the AvatarKit rendering pipeline. It extracts
                      H.264 SEI side-channel data off Agora's encoded-frame observer and
                      feeds animation packets into the AvatarKit player.
                      DESC
  spec.homepage     = "https://github.com/spatius-ai/avatarkit-ios-rtc"
  spec.license      = {
    :type => "Commercial",
    :text => "Copyright © 2026 Spatius. All rights reserved. Use is subject to the Spatius commercial license agreement."
  }
  spec.author       = { "Spatius" => "hello@spatialwalk.net" }
  spec.platform     = :ios, "16.0"
  spec.swift_version = "6.0"
  spec.source       = { :git => "https://github.com/spatius-ai/avatarkit-ios-rtc.git", :tag => "v#{spec.version}" }

  # Swift facade: public API + Agora provider + SEI parsing.
  # Paths are relative to the repo root (what `:git` checks out), so they
  # include the `AvatarKitRTC/` package subdirectory prefix.
  spec.source_files = "AvatarKitRTC/Sources/AvatarKitRTC/**/*.swift"

  # The host SDK ships an arm64-only simulator slice. A pod dependency's xcconfig
  # does not propagate to the dependent pod's target, so the exclusion declared in
  # the host podspec applies only to itself and to the host app — this target would
  # still build for x86_64, at which point the whole AvatarKit module fails to
  # resolve and every public type reports "cannot find in scope". Declare the same
  # exclusion here.
  #
  # What this excludes is only the Intel Mac simulator, which the host SDK does
  # not support anyway: the Metal renderer and the SPCoreLibrary binary dependency
  # are both arm64-only, so an x86_64 slice cannot be produced at all (see the host
  # SDK's Scripts/build_avatarkit.sh). The simulator works as usual on Apple Silicon.
  spec.pod_target_xcconfig = {
    "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "x86_64"
  }
  spec.user_target_xcconfig = {
    "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => "x86_64"
  }

  # AvatarKitAgoraBridge is a separate pod (not a subspec) so it compiles as its
  # own Clang module — the Swift sources do `import AvatarKitAgoraBridge`, which
  # only resolves against a standalone module, matching the SPM target layout.
  spec.dependency "AvatarKitAgoraBridge", "1.0.1"
  # The host SDK is published to CocoaPods as SpatiusAvatarKit — `AvatarKit` was
  # already taken by someone else, and depending on that name pulls an unrelated
  # package. Its module_name is still AvatarKit, so imports are unaffected.
  spec.dependency "SpatiusAvatarKit", "1.3.4"
  spec.dependency "SwiftProtobuf", "1.30.0"
  spec.dependency "AgoraRtcEngine_iOS", "4.5.2"
end
