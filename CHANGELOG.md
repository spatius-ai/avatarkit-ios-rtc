# Changelog

## [1.0.0-beta.7] — 2026-08-06

### Breaking

- **`AvatarSDK` must be initialized with `drivingServiceMode: .rtc`**. The value is
  checked when constructing `AvatarPlayer`, and any other mode aborts outright.
  There was no check before, which left RTC session telemetry indistinguishable
  from that of a plain AvatarKit integration.

  ```swift
  AvatarSDK.initialize(
      appID: appID,
      configuration: Configuration(drivingServiceMode: .rtc)
  )
  ```

### Added

- **`AvatarPlayer.attach(to:)` / `detach()`** — support for a host-owned Agora
  engine. Integrators that already own and manage an `AgoraRtcEngineKit` can hand
  the engine to the SDK: the SDK only borrows it, installing the encoded-frame SEI
  observer and enabling SEI. It does not create, join a channel with, or destroy
  the engine.

### Changed

- Bumped the host SDK dependency to `1.3.1-beta.2` (SPM and CocoaPods in sync).
- Corrected the CocoaPods host SDK pod name to `SpatiusAvatarKit` — the name
  `AvatarKit` is already taken by someone else, so the previous declaration pulled
  in an unrelated package. `import AvatarKit` is unaffected.
- Transition frames and stream frames now share a single scheduling clock, aligned
  with web, for steadier playback pacing.

### Fixed

- **`detach()` picture jump** — it used to cut straight to the idle start frame,
  producing a visible jump when tearing down a host-engine session; it now matches
  `disconnect()` and plays a smooth transition first.
- **Stall and frame-rate accounting** — stall intervals used to be settled only
  when stream frames rendered, so the trailing transition frames were missed;
  transport-layer stats never actually took effect.
- **Round-trip time (RTT)** — now derived from `lastmileDelay` and converted to a
  round-trip value; previously not a single sample was reported successfully.

## [1.0.0-beta.6] — 2026-07-09

### Changed

- Downgraded the Agora SDK (`AgoraRtcEngine_iOS`) dependency from `4.6.2` to
  `4.5.2`. The encoded-frame callback interface was adapted to the Agora 4.5.x
  signature accordingly.

## [1.0.0-beta.5] — 2026-07-08

### Added
- CocoaPods integration support: added two podspecs, `AvatarKitRTC` and
  `AvatarKitAgoraBridge`, so the SDK can be pulled in via CocoaPods (previously
  Swift Package Manager only). Depends on the `AvatarKit` and
  `AgoraRtcEngine_iOS` CocoaPods packages.

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
