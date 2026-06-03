# Changelog

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
