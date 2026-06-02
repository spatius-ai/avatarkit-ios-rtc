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

`AvatarKitRTC` only drives the **speaking** state — when a conversation
ends the renderer is returned to AvatarKit's own idle loop.

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

try await player.connect(AgoraConnectionConfig(
    appId: agoraAppID,
    channel: channelName,
    token: token,
    uid: uid
))
try await player.publishAudio()                  // mic on for two-way talk
```

## Demo

`Demo/RTCDemo.xcodeproj` is a single-screen SwiftUI app that:
1. Reads three fields you fill in at launch — **Backend base URL**, **App ID**,
   and **Avatar ID**. None are bundled; you point the demo at your own
   AvatarKit backend.
2. Initializes AvatarKit with that App ID.
3. Loads the avatar by id.
4. Fetches an Agora token from `{baseURL}/api/agora-token` (the demo backend
   you supply must expose this endpoint).
5. Connects via `AvatarPlayer` and publishes the microphone.

Open it directly — the package dependency is a local sibling path to AvatarKitRTC.

## License

MIT
