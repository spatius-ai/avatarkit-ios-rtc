# AvatarKitRTC (iOS)

RTC adapter for [AvatarKit](https://github.com/spatius-ai/avatarkit-ios) on iOS — bridges animation tracks from RTC providers into AvatarKit's rendering pipeline.

This is the iOS counterpart of [`@spatius/avatarkit-rtc`](https://www.npmjs.com/package/@spatius/avatarkit-rtc); the public API mirrors the web package 1:1 where the platforms allow.

## Status

End-to-end working with **Agora** on iOS 16+. Drop-in: an `AvatarView` plus an `AgoraProvider` is all the host app needs.

## Architecture

```
Agora encoded video (H.264) ─┐
                             │
                  IVideoEncodedFrameObserver  (C++)
                             │  ObjC++ bridge
                             ▼
                  AKAgoraEncodedFrameObserver
                             │  Annex-B slicing + SEI parsing
                             ▼
                    SEIPacketParser
                             │  animation payload bytes
                             ▼
                    AnimationHandler  ──►  AvatarView
                  (jitter buffer / transitions /
                   stall watchdog / telemetry)
```

`AvatarKitRTC` only drives the **speaking** state — when a conversation ends the renderer is returned to AvatarKit's own idle loop.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/spatius-ai/avatarkit-ios-rtc.git", from: "1.0.0")
```

The package transitively pulls in:
- `AvatarKit` (peer)
- `AgoraRtcEngine_iOS` 4.6.2 (`RtcBasic`)
- `SwiftProtobuf` 1.30.0

CocoaPods:

```ruby
pod 'AvatarKitRTC', '~> 1.0'
```

## Quick start

```swift
import AvatarKit
import AvatarKitRTC

let view = AvatarView(avatar: avatar)            // standard AvatarKit setup
let provider = AgoraProvider()
let player = AvatarPlayer(provider: provider,
                          avatarView: view,
                          options: AvatarPlayerOptions(logLevel: .info))

player.subscribe { event in
    switch event {
    case .connected:                 print("connected")
    case .disconnected:              print("disconnected")
    case .error(let msg):            print("error: \(msg)")
    case .stalled:                   print("stream stalled")
    case .connectionStateChanged:    break
    }
}

try await player.connect(AgoraConnectionConfig(
    appId: agoraAppID,
    channel: channelName,
    token: token,
    uid: uid
))
try await player.publishAudio()                  // mic on for two-way talk

// ... conversation ...

await player.unpublishAudio()
await player.disconnect()                        // 12-frame soft transition back to idle
```

## Public API

### `AvatarPlayer`

The main entry point. One instance per `AvatarView` per RTC session.

```swift
@MainActor public final class AvatarPlayer {
    public init(provider: RTCProvider,
                avatarView: AvatarView,
                options: AvatarPlayerOptions = AvatarPlayerOptions())
}
```

**Connection lifecycle**

| Method | Purpose |
|---|---|
| `connect(_ config: RTCConnectionConfig) async throws` | Join the RTC session described by `config` (for Agora pass `AgoraConnectionConfig`). Subscribes to the agent's video / data tracks; animation frames start flowing through the jitter buffer into the `AvatarView`. |
| `disconnect() async` | Leave the session. Plays a short transition back to idle so the avatar returns to the idle loop smoothly instead of hard-cutting. Safe to call repeatedly. |
| `reconnect() async throws` | Re-issue `connect` using the last `RTCConnectionConfig`. Use when the provider raises `.connectionStateChanged(.reconnecting)` for too long. |
| `var isConnected: Bool` | Read-only current connection state. |

**Audio I/O (microphone)**

| Method | Purpose |
|---|---|
| `publishAudio() async throws` | Capture the device mic and publish it on the RTC channel so the agent can hear the user. Requires the `NSMicrophoneUsageDescription` Info.plist key and a granted permission. |
| `unpublishAudio() async` | Stop publishing the mic. The connection stays open — call this when the user mutes. |
| `publishExternalPCM(sampleRate: Int = 16000, channels: Int = 1) async throws` | Alternative to `publishAudio` for hosts that already have a PCM source (e.g. an in-app recorder, an audio file player). Tells the provider to expect external PCM via `pushPCM` instead of capturing from the mic. |
| `pushPCM(_ data: Data) async` | Push a chunk of raw PCM samples after `publishExternalPCM`. The chunk size and cadence is at the caller's discretion. |

**Session inspection**

| Member | Purpose |
|---|---|
| `var sessionSummary: AnimationSessionSummary` | Cumulative playback / jitter-buffer counters for the current connection. Read in tests or in dev overlays to verify ordering, drops, skips, stalls. Reset on `connect`. Also emitted as the `rtc_session_summary` telemetry event on `disconnect`. |
| `subscribe(_ handler: @escaping (AvatarPlayerEvent) -> Void) -> Int` | Register an event subscriber and get back a subscription id. Multiple subscribers are allowed. Currently returned id is informational; subscribers live for the player's lifetime. |

### `AvatarPlayerOptions`

Tuning knobs passed to `AvatarPlayer.init`. All defaults are sensible for live two-way talk.

```swift
public struct AvatarPlayerOptions: Sendable {
    public var logLevel: RTCLogLevel = .warning
    public var enableJitterBuffer: Bool = true
    public var maxBufferDelayMs: Int = 80
}
```

- `logLevel` — `.off / .error / .warning / .info / .debug`. Affects only the SDK's `print`-style log; SDK telemetry is independent.
- `enableJitterBuffer` — turn off only for tests that need every frame rendered in arrival order. Real sessions always want this on.
- `maxBufferDelayMs` — soft ceiling. Larger values absorb more network jitter but add latency between agent speech and avatar motion.

### `AvatarPlayerEvent`

Pushed to subscribers registered via `AvatarPlayer.subscribe`.

| Case | When |
|---|---|
| `.connected` | RTC session is up and the agent track is subscribed. |
| `.disconnected` | Session torn down (manual `disconnect`, network drop, or fatal error). |
| `.error(String)` | Non-fatal SDK error — surface to user, no need to teardown. |
| `.stalled` | No animation frames for 5 s. Usually means the server-side agent died; pair with `reconnect()` or surface to user. |
| `.connectionStateChanged(RTCConnectionState)` | Lower-level provider transitions: `.disconnected / .connecting / .connected / .reconnecting / .failed`. |

### `AgoraConnectionConfig`

Conforms to `RTCConnectionConfig`. The four fields you would normally pass to `AgoraRtcEngine.joinChannel`.

```swift
public struct AgoraConnectionConfig: RTCConnectionConfig {
    public init(appId: String, channel: String, token: String? = nil, uid: UInt? = nil)
}
```

- `appId` — Agora project App ID (not the AvatarKit App ID).
- `channel` — channel name shared with the server-side agent.
- `token` — Agora token, or `nil` for App-ID-only channels (dev only).
- `uid` — local user uid. Pass `nil` to let Agora assign one.

The SDK does **not** fetch tokens. Generate them server-side and pass them in.

### `AgoraProvider`

The only `RTCProvider` implementation shipped. Concrete class — instantiate with `AgoraProvider()` and hand it to `AvatarPlayer`. Internally it owns the `AgoraRtcEngine`, subscribes to encoded video frames, extracts SEI, and forwards parsed animation packets to the `AnimationHandler`.

There is no public configuration on the provider itself — everything you can change goes through `AvatarPlayerOptions` or `AgoraConnectionConfig`.

### Supporting types

- `AnimationSessionSummary` — frame / jitter / loss counters for the most recent session. See `AnimationHandler.swift` for the field list.
- `RTCStreamStats` — provider-level per-second snapshot (FPS, lost / recovered / dropped / out-of-order / duplicate frames). Updated by `AgoraProvider`.
- `AnimationFrameMetadata` — per-frame flags from the wire (`isStart / isEnd / isIdle / isRecovered`). Useful when wiring custom analytics.
- `RTCConnectionState`, `RTCProviderError`, `AgoraProviderError`, `AvatarPlayerError` — error / state enums. All conform to `LocalizedError` where appropriate.
- `RTCLogLevel` — `.off / .error / .warning / .info / .debug`. Passed via `AvatarPlayerOptions.logLevel`.

## Demo

`Demo/RTCDemo.xcodeproj` is a single-screen SwiftUI app that drives `AvatarPlayer` end-to-end. Tap the gear icon to open the config sheet:

1. **AvatarKit** — `App ID` (initializes the SDK) and `Avatar ID` (asset to load).
2. **Agora** — `App ID`, `Channel`, `Token`, `UID`. These are exactly the four fields of `AgoraConnectionConfig` — the SDK has no token-fetch logic, so the demo expects you (or your backend) to supply them directly. `UID` defaults to 0 when blank; `Token` is optional for App-ID-only channels.

All fields are persisted in `UserDefaults`. Hit **Load Avatar**, then **Connect**.

## License

MIT
