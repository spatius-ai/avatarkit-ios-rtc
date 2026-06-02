Pod::Spec.new do |spec|
  spec.name         = "AvatarKitRTC"
  spec.version      = "1.0.0-beta.1"
  spec.summary      = "RTC adapter for AvatarKit"
  spec.description  = <<-DESC
                      AvatarKitRTC bridges audio/animation tracks from RTC providers
                      (LiveKit, Agora, ...) into the AvatarKit rendering pipeline.
                      DESC
  spec.homepage     = "https://github.com/spatius-ai/avatarkit-ios-rtc"
  spec.license      = { :type => "MIT" }
  spec.author       = { "Spatius" => "code@spatius.net" }
  spec.platform     = :ios, "16.0"
  spec.swift_version = "6.0"
  spec.source       = { :git => 'https://github.com/spatius-ai/avatarkit-ios-rtc.git', :tag => spec.version.to_s }
  spec.source_files = "Sources/AvatarKitRTC/**/*.swift"
  # Peer dependency on AvatarKit — pin to a published version.
  # spec.dependency 'AvatarKit', '~> 1.0'
end
