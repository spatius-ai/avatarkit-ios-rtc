# Changelog

## [1.0.0-beta.6] — 2026-07-09

### Changed

- 依赖的声网 SDK（`AgoraRtcEngine_iOS`）版本由 `4.6.2` 降为 `4.5.2`。
  编码帧回调接口随之适配声网 4.5.x 签名。

## [1.0.0-beta.5] — 2026-07-08

### Added
- CocoaPods 集成支持：新增 `AvatarKitRTC` 与 `AvatarKitAgoraBridge` 两个 podspec，
  可通过 CocoaPods 引入（此前仅支持 Swift Package Manager）。依赖 `AvatarKit`
  与 `AgoraRtcEngine_iOS` 的 CocoaPods 包。

## [1.0.0-beta.4] — 2026-06-20

### Added
- `AvatarPlayer.getNativeClient()` — exposes the underlying native RTC client
  (Agora's `AgoraRtcEngineKit`) for advanced use cases not covered by the
  unified API. Returns `nil` when not connected. Aligns with Android / web.

### Fixed
- **Missing start transition when conversations overlap** — if a new
  conversation's start transition arrives while the previous conversation's
  speak→idle end transition is still playing (server cadence / network jitter
  overlapping conversations), the end transition is now stopped and session
  tracking reset so the start transition plays normally, anchored on the
  current frame for a smooth continuation. Previously it was dropped as a
  "late" packet, causing a visible jump on the opening frame.

### Changed
- Default end-transition length increased from 12 to 20 frames to match server
  cadence, aligning with web / Android.

## [1.0.0-beta.3] — 2026-06-09

### Added
- `AvatarPlayer.publishAudio()` / `publishExternalPCM(sampleRate:channels:)` now
  emit an `rtc_audio_publish_failed` telemetry event (provider + error
  description) when publishing fails, aligning the telemetry surface with the
  web RTC SDK.

### Changed
- Demo `Info.plist`: added `NSCameraUsageDescription` (the RTC SDK links against
  camera APIs even though the demo does not use the camera).

### Compatibility
- Requires AvatarKit iOS SDK v1.1.0-beta.1 or later.

## [1.0.0-beta.2] — 2026-06-03

### Changed
- `AvatarPlayer.disconnect` now plays a 12-frame transition back to idle
  using the same `generateTransitionToIdle` path the server-driven
  end-transition uses, so disconnect feels like a normal conversation
  end instead of hard-cutting to idle.
- Demo: replaced the inline backend-URL-driven token fetch with a gear
  icon config sheet. Integrators supply the four `AgoraConnectionConfig`
  fields (appId / channel / token / uid) directly, matching how a real
  host app would wire up the SDK.

### Compatibility
- Requires AvatarKit iOS SDK v1.0.0-beta.2-rtc or later.

## [1.0.0-beta.1] — 2026-06-02

### Added
- `AvatarPlayer` / `AnimationHandler` — end-to-end playback with jitter
  buffer, transition handling, stall watchdog, and session telemetry.
  Public API mirrors the web `@spatius/avatarkit-rtc` package.
- `AgoraProvider` — Agora RTC provider for iOS. Uses an Objective-C++
  bridge (`AvatarKitAgoraBridge`) over `IVideoEncodedFrameObserver` to
  surface raw H.264 NAL units, then extracts SEI user-data payloads in
  pure Swift (`H264SEIExtractor` + `SEIPacketParser`).
- `Demo/RTCDemo.xcodeproj` — standalone SwiftUI demo. Fill in your own
  backend URL, app id and avatar id at launch.

### Compatibility
- Requires the AvatarKit iOS SDK v1.0.0-beta.1-rtc or later.
