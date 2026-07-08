Pod::Spec.new do |spec|
  spec.name         = "AvatarKitRTC"
  spec.version      = "1.0.0-beta.5"
  spec.summary      = "RTC adapter for AvatarKit"
  spec.description  = <<-DESC
                      AvatarKitRTC bridges audio/animation tracks from RTC providers
                      (Agora, ...) into the AvatarKit rendering pipeline. It extracts
                      H.264 SEI side-channel data off Agora's encoded-frame observer and
                      feeds animation packets into the AvatarKit player.
                      DESC
  spec.homepage     = "https://github.com/spatius-ai/avatarkit-ios-rtc"
  spec.license      = { :type => "Commercial" }
  spec.author       = { "Spatius" => "hello@spatialwalk.net" }
  spec.platform     = :ios, "16.0"
  spec.swift_version = "6.0"
  spec.source       = { :git => "https://github.com/spatius-ai/avatarkit-ios-rtc.git", :tag => "v#{spec.version}" }

  # Swift facade: public API + Agora provider + SEI parsing.
  # Paths are relative to the repo root (what `:git` checks out), so they
  # include the `AvatarKitRTC/` package subdirectory prefix.
  spec.source_files = "AvatarKitRTC/Sources/AvatarKitRTC/**/*.swift"

  # AvatarKitAgoraBridge is a separate pod (not a subspec) so it compiles as its
  # own Clang module — the Swift sources do `import AvatarKitAgoraBridge`, which
  # only resolves against a standalone module, matching the SPM target layout.
  spec.dependency "AvatarKitAgoraBridge", "1.0.0-beta.5"
  spec.dependency "AvatarKit", "1.3.0"
  spec.dependency "SwiftProtobuf", "1.30.0"
  spec.dependency "AgoraRtcEngine_Special_iOS", "4.5.2.191.BASIC"
end
