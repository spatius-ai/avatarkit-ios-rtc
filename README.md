# AvatarKitRTC iOS SDK

> **Agora special build for iOS 13 deployment targets — `1.2.0-agora-special.4.5.2.191.BASIC-compat-ios13`.**
> This branch is AvatarKitRTC 1.2.0 built against Agora's customer SDK
> **`AgoraRtcEngine_Special_iOS 4.5.2.191.BASIC`** instead of the public
> `AgoraRtcEngine_iOS 4.5.2`, with a 13.0 deployment target and every API marked
> iOS 16+ (see Requirements). It depends on AvatarKit `1.3.6-compat-ios13`. Apart
> from that, the code is identical to
> [`v1.2.0`](https://github.com/spatius-ai/avatarkit-ios-rtc/tree/v1.2.0).
>
> - **CocoaPods only:** `pod 'AvatarKitRTC', '1.2.0-agora-special.4.5.2.191.BASIC-compat-ios13'` (pulls
>   `AgoraRtcEngine_Special_iOS 4.5.2.191.BASIC` and `SpatiusAvatarKit 1.3.6-compat-ios13`). Do not also add
>   `AgoraRtcEngine_iOS` — two Agora SDKs in one app conflict.
> - **Offline:** `AvatarKitRTC-1.2.0-agora-special.4.5.2.191.BASIC-compat-ios13-xcframeworks.zip` on this tag's GitHub Release.
> - **Not SPM:** Agora ships no special SDK over SPM. The SPM instructions below
>   (and `Package.swift`) are the public build's.

RTC adapter for [AvatarKit](https://github.com/spatius-ai/avatarkit-ios-release) on iOS — brings an agent's animation stream from an RTC session into AvatarKit's rendering pipeline. Currently supports Agora.

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/spatius-ai/avatarkit-ios-rtc.git", from: "1.2.0")
]
```

## Requirements

- iOS 13.0+ deployment target (`compat-ios13` build). Every AvatarKitRTC API is marked
  `@available(iOS 16.0, *)`: call it inside `if #available(iOS 16.0, *)`. On iOS 13–15
  the app links and launches, but AvatarKitRTC must not be used.
- arm64
- `AvatarKit` 1.3.6-compat-ios13
- `AgoraRtcEngine_iOS` 4.5.2 exactly — other versions are not supported: 4.6.x changed the
  encoded-frame callback, and 4.5.3 builds but delivers no avatar frames at runtime

## Documentation

Full quickstart, API reference, and integration guides:

**https://docs.spatius.ai/sdk-reference/web-sdk/rtc-adapter**

The public API mirrors the web package, so the reference above applies to iOS as well.

## Support

- Email: hello@spatialwalk.net
- Docs: https://docs.spatius.ai
