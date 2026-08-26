# Architecture Overview — iOS RTC SDK

Layer: **current state** — describes the SDK as it is at HEAD. Present tense.
Rewritten in place whenever the code changes; re-verified against source on every
release (→ `knowledge/workflows/release-workflow.md` §1.1).

Pods `AvatarKitRTC` + `AvatarKitAgoraBridge`, v1.0.0. Swift 6.

**This is the RTC glue layer** for the main SDK `AvatarKit`. It pulls animation
data out of an RTC video stream and drives the main SDK's `AvatarView`.

## 1. Source layout

Two SPM targets: 13 Swift files under `Sources/AvatarKitRTC/`, plus a 2-file
ObjC++ bridge under `Sources/AvatarKitAgoraBridge/`.

| File | Lines | Responsibility |
|------|------:|---------------|
| `AvatarPlayer.swift` | 763 | **Entry point.** Lifecycle, provider event fan-out, telemetry aggregation, transport-stats sampling. Holds two `private` bridges: `ViewRendererAdapter` (`:701`), `AnimationCallbacksBridge` (`:741`) |
| `AnimationHandler.swift` | 1556 | **Playback core.** Jitter buffer, the single playback clock, transition generation, stall watchdog, per-round stats and traces. Not public |
| `RTCProvider.swift` | 249 | `AnimationTrackCallbacks` (`:7`), `TransportStats` (`:52`), `RTCProviderEvent` (`:102`), `RTCProvider` (`:112`), `BaseRTCProvider` (`:167`) |
| `Types.swift` | 86 | Pure data types; imports only Foundation |
| `Providers/AgoraProvider.swift` | 560 | The only provider. Engine lifecycle, encoded-frame observer, external-engine attach, audio publishing, transport stats |
| `Providers/H264SEIExtractor.swift` | 163 | **Stateless `enum`.** NAL slicing, SEI NALU parsing, EBSP→RBSP |
| `Providers/SEIPacketParser.swift` | 351 | `@MainActor final class`. Our own SEI wire format → typed events. **Carries session state** |
| `Utils/Telemetry.swift` | 189 | Forwards to the host's `@_spi(RTC) RTCTelemetry` |
| `Utils/TelemetryIdentity.swift` | 33 | `AvatarSDK.inject(...)` — see §5 |
| `Utils/ConversationId.swift` | 45 | Local round id; **not** a server conversation id (`:9-14`) |
| `Utils/Logger.swift` | 60 | `RTCLogger` over `os.Logger`, subsystem `ai.spatius.avatarkit.rtc` |
| `Utils/TelemetryRecorder.swift` | 175 | Mirrors four telemetry channels to a file. **Off by default** |
| `Utils/PlaybackProbe.swift` | 88 | Frame-on-screen CSV probe. **Off by default** |
| `AvatarKitAgoraBridge/*.mm` + `include/*.h` | 71 + 39 | ObjC++ wrapper turning Agora's C++ `IVideoEncodedFrameObserver` into a Swift block |

## 2. Public API

`AvatarPlayer` (`@MainActor public final class`, `:46`):

```swift
public func connect(_ config: RTCConnectionConfig) async throws          // :173
public func attach(to engine: AgoraRtcEngineKit) throws                  // :224  ← synchronous
public func detach() async                                               // :258
public func disconnect() async                                           // :283
public func publishAudio() async throws                                  // :334
public func unpublishAudio() async                                       // :348
public func publishExternalPCM(sampleRate:channels:) async throws        // :360
public func pushPCM(_ data: Data) async                                  // :376
public func reconnect() async throws                                     // :381
@discardableResult public func subscribe(_:) -> Int                      // :417
public func getNativeClient() -> Any?                                    // :426
public var isConnected: Bool                                             // :57
public var sessionSummary: AnimationSessionSummary                       // :63
```

Also public: `AvatarPlayerOptions`, `AvatarPlayerEvent`, `AvatarPlayerError`,
`AgoraProvider`, `AgoraProviderError`, the three provider abstractions, all of
`Types.swift`, `RTCLogLevel`, `AnimationSessionSummary`, and the two diagnostic
tools `PlaybackProbe` / `TelemetryRecorder`.

`AnimationHandler` itself is **not** public — only its `AnimationSessionSummary`
and `getSessionSummary()` (`:588`) are.

> ⚠️ **`subscribe(_:)` returns a token for an `unsubscribe(_:)` that does not
> exist.** The doc comment (`:415`) promises it; grep finds no such method on
> `AvatarPlayer` (the `unsubscribeAnimationTrack` hits are the provider's,
> unrelated). The returned `Int` has no use and `subscribers` only ever grows.

## 3. Provider abstraction

`@MainActor public protocol RTCProvider: AnyObject` (`RTCProvider.swift:112`).
`BaseRTCProvider` (`:167`) inherits `NSObject` so subclasses can adopt
`AgoraRtcEngineDelegate`, and supplies the state machine plus event boilerplate;
the rest is `fatalError("subclass must override …")`.

**`AgoraProvider` is the only implementation** — no LiveKit anywhere.

> A trap worth keeping (`RTCProvider.swift:187-195`): `getTransportStats` must be
> declared `open` **on the class**, not left as a protocol-extension default.
> Otherwise a subclass's apparent override never enters the vtable, and calling
> through an `RTCProvider`-typed reference silently returns nothing — which once
> left every transport metric empty.

## 4. Data flow

```
Agora C++ IVideoEncodedFrameObserver           (Agora's aosl_main thread)
  └─ AKAgoraEncodedFrameObserver.mm:16 → NSData copy
     └─ handler block                           AgoraProvider.swift:355
        └─ workQueue.async "ai.spatius.rtc.agora-nal"   (:352, serial, .userInitiated)
           ├─ H264SEIExtractor.extractUserDataPayloads  (:364)
           └─ Task { @MainActor }                       (:380)
              └─ SEIPacketParser.handleSEIPayload       (:386)
                 └─ AnimationTrackCallbacks → AnimationCallbacksBridge  (:741)
                    └─ AvatarPlayer.handleAnimationData / …             (:460-503)
                       └─ AnimationHandler → jitter buffer → clock tick
                          └─ AvatarView.renderFromProtobufSync          (:710)
```

### Why two SEI classes

**`H264SEIExtractor`** is the container layer — stateless, pure H.264. It slices
Annex-B NALs (`:59`), accepts only `nalType == 6` with payload type 5 or 101
(`:99`, `:134`), and strips emulation prevention bytes (`:145`). Its header
(`:11-15`) is explicit that this layer *cannot* tell which SEIs are ours.

**`SEIPacketParser`** is the business layer and **carries session state** — the
`lastWasIdle` / `isInStartTransition` / `isInEndTransition` latches. Format is
`[1B flags][4B msgLen LE][payload]` (`:10`) with flags
`idle 0x01 / start 0x02 / end 0x04 / gzipped 0x08 / transition 0x10 /
transitionEnd 0x20` (`:23-30`) — identical to Android and web. It unescapes
`00 FF→00` / `FF FF→FF` (`:152`), inflates zlib (`:156`), and knows that regular
frames carry a `[4B frameSeq]` prefix while transition frames do not (`:177-186`).

> **Web has no equivalent of `H264SEIExtractor`** — Agora's JS SDK delivers a
> `sei-received` event directly. iOS and Android both must slice NALs themselves.

## 5. Coupling to the main SDK

| Distribution | Main SDK dependency | Version |
|--------------|--------------------|---------|
| `Package.swift:17` | `avatarkit-ios-release` → `AvatarKit` | **`exact: "1.3.3"`** |
| `AvatarKitRTC.podspec:47` | pod **`SpatiusAvatarKit`** | **`"1.3.3"`** |

> The pod is named `SpatiusAvatarKit` because `AvatarKit` was taken on trunk
> (`podspec:45-46`); its `module_name` is still `AvatarKit`, so `import` is
> unchanged.

> **Unlike Android, iOS pins the main SDK exactly.** Android declares it
> `compileOnly`, which produces no POM constraint at all — a host on an
> incompatible version gets no check whatsoever. Both SPM and CocoaPods here
> enforce 1.3.3.

Third-party deps are pinned too: SwiftProtobuf 1.30.0, AgoraRtcEngine_iOS 4.5.2.

**Only `AvatarView` is used — there is no `AvatarController`.** Calls go through
`ViewRendererAdapter` (`AvatarPlayer.swift:701-735`):
`renderFromProtobufSync`, `renderFrameSync`, `generateTransitionToFrameSync`,
`generateTransitionToIdle`.

**Mode is enforced with `preconditionFailure`** (`:119-131`) — the host must have
initialized with `drivingServiceMode: .rtc`, and a release build traps too. The
reasoning (`:101-118`): a wrong mode tags the whole session's telemetry with the
wrong `dsm`, and it cannot be corrected after the fact. This is stricter than
Android, which throws a catchable exception.

**Telemetry identity is claimed at `AvatarPlayer` construction**
(`AvatarPlayer.swift:141` → `TelemetryIdentity.claim()`), injecting
`sdk_package = "spatius-ios-rtc"` and `sdk_version`.

> That timing works **only because of an iOS-specific window**
> (`TelemetryIdentity.swift:11-17`): the OTel Resource is built inside a `Task`
> spawned by `AvatarSDK.initialize()`, after region resolution — not
> synchronously within the call. Android has no such window (its Resource is
> built synchronously inside `initialize()`), which is why that SDK needs a
> ContentProvider to claim identity before app code runs.

> ⚠️ **`TelemetryIdentity.sdkVersion` is hand-written**, because Swift Package
> Manager offers no build-time substitution — a package cannot read its own
> podspec or git tag. Web derives this from package.json via Vite's `define`;
> Android from `gradle.properties` via `BuildConfig`. **iOS is the only layer
> with no automatic source**, so this constant *is* the source of truth.
>
> It has drifted twice: stuck at beta.6 through the whole beta.7 release
> (`dc3aee9`), then at `1.0.0-beta.9` after `52f258d release: v1.0.0` bumped the
> podspecs and missed this file — **every telemetry record shipped from v1.0.0
> carries a version that was never released**, and those artifacts cannot be
> corrected retroactively. HEAD is now correct, and
> `scripts/check_version_consistency.sh` fails the release when the constant and
> the two podspecs disagree.
> → [`release-process.md`](release-process.md) §2

### `AnimationHandler` is only partly decoupled

It has the same `AvatarRendererAdapter` abstraction as Android and web
(`AnimationHandler.swift:15-21`, five methods), **but `AnimationHandler.swift:2`
is `@_spi(RTC) import AvatarKit`** and the protocol's own signatures carry the
main SDK's `Frame` type (`:17-19`), as does `transitionFrames: [Frame]` (`:172`).
So the abstraction isolates `AvatarView`, not AvatarKit's type system —
**identical to Android; web is the only one with a truly zero-dependency
handler.**

> All five adapter methods are **synchronous**, and `:8-14` explains this is
> load-bearing: an async render only guarantees "handed off within this slot",
> not "on screen within this slot", and two frames' continuations can resume out
> of order, letting an older frame overwrite a newer one.

## 6. Jitter buffer and transitions

**Every constant matches Android and web exactly:**

| Constant | Value | Location |
|----------|------:|----------|
| `stallTimeoutMs` | 5000 | `AnimationHandler.swift:199` |
| `bufferMaxSize` | 4 | `:213` |
| `bufferInitialFill` | 2 | `:214` |
| `frameIntervalMs` | 40 | `:234` |
| `transitionStartFrameCount` | 8 | `:25` |
| `transitionEndFrameCount` | **40** | `:26` |
| `maxBufferDelayMs` | 80 | `:30` |
| `DISCONNECT_TRANSITION_FRAMES` | 12 | `AvatarPlayer.swift:47` |

`SEIPacketParser.swift:34-35` mirrors the two transition counts, same as Android.

**Actual frame counts** are structurally identical to the other two: the start
transition plays `8 + (bufferInitialFill - 1) = 9` (`:409-410`), generating N+1
and dropping the last (`:424-425`) because the generator's final frame equals the
target, which is also the stream's first frame.

**The end transition owes slots before it begins** (`:475-478`) and **only slots
that actually rendered pay the debt** (`:1280`). `beginEndTransition` resumes the
existing grid rather than re-anchoring (`:525`).

**Start is judged by seq, not buffered count** (`:1108-1109`) — `:1092-1107`
explains that counting frames leaves the picture permanently behind the audio
when a round opens with a loss.

**One clock**: `playbackTick()` (`:1269-1293`) renders exactly one thing per slot
(`:1272`). `:216-223` records the bug this fixed — two independent chains once
produced a 28ms/40ms seam at the hand-over with two writers on the renderer at
once.

## 7. Lifecycle — two routes

**Route A (managed)**: `connect` (`:173`) → `provider.connect`
(`AgoraProvider.swift:58`): create engine → `enable_sei` → `.chorus` audio
scenario → `.broadcaster` → **install observer, then join** (`:88-92`) → await
Connected or **15s timeout** (`:107-117`).
`disconnect` (`:283`) → unpublish → stop sampling → `provider.disconnect()`
(observer detach, `leaveChannel`, `destroy`) → `dispose()` →
**`playTransitionToIdle()`** (12 frames) → `rtc_session_summary` +
`rtc_disconnected`.

**Route B (external engine)**: `attach(to:)` (`:224`) is **synchronous
`throws`** — `guard let agora = provider as? AgoraProvider else { throw
.externalEngineUnsupported }` (`:228-230`) → `attachExternalEngine`
(`AgoraProvider.swift:186`): `enable_sei` failure throws immediately (`:199-202`),
observer failure rolls back and throws (`:213-218`) → state `.connected`.
`detach()` (`:258`) is `async` because it plays a transition;
`detachExternalEngine` only removes the observer and **never** leaves or destroys
the host's engine (`:230-241`).

**attach must precede the host's `joinChannel`** (`:213-220`): `enable_sei` only
affects subsequent joins, and route B has no join-timeout fallback, so a silent
failure becomes an unexplained black screen.

> **Same shape as Android, different from web**: attach is Agora-only and hard
> type-checked; attach is synchronous while detach is async.

## 8. Threading

`AvatarPlayer`, `AnimationHandler`, `SEIPacketParser` and `AgoraProvider` are all
`@MainActor` (`:46`, `:159`, `:22`, `:15`), as are the `AnimationTrackCallbacks`
and `RTCProvider` protocols. **Rendering is on the main thread.** There is no
`actor` anywhere — concurrency is `@MainActor` + `Task` + one queue.

**The one background queue** is `"ai.spatius.rtc.agora-nal"`
(`AgoraProvider.swift:352`), carrying NAL slicing and SEI extraction. `:338-346`
documents the three-stage reasoning: Agora's callback runs on its internal
`aosl_main` thread guarded by `dispatch_assert_queue` — doing work there trips
`EXC_BREAKPOINT`, so you must leave immediately; slicing happens on the dedicated
serial queue; and the MainActor is only touched when there is actually a payload
(`:379`), avoiding ~25 empty Tasks per second on the UI thread.

**All timers are `Task` + `Task.sleep`** — no `Timer`, no `CADisplayLink`:
playback clock (`:1253`), stall watchdog (`:633`), playback stats (`:661`),
SEI stats (`SEIPacketParser.swift:251`), join timeout (`AgoraProvider.swift:109`).

Agora delegate callbacks are `nonisolated` and hop back via
`Task { @MainActor [weak self] … }`. `PlaybackProbe` and `TelemetryRecorder` are
`@unchecked Sendable` + `NSLock` since they are written from any thread.

## 9. Why two podspecs

| | `AvatarKitRTC.podspec` | `AvatarKitAgoraBridge.podspec` |
|---|---|---|
| Sources | `Sources/AvatarKitRTC/**/*.swift` (`:24`) | `Sources/AvatarKitAgoraBridge/**/*.{h,mm}` (`:21`) |
| Dependencies | AvatarKitAgoraBridge 1.0.0, SpatiusAvatarKit 1.3.3, SwiftProtobuf 1.30.0, AgoraRtcEngine_iOS 4.5.2 (`:44-49`) | AgoraRtcEngine_iOS 4.5.2 only (`:24`) |
| Extra config | `EXCLUDED_ARCHS[sdk=iphonesimulator*] = x86_64`, declared **twice** (`:34-39`) | `c++17` + `libc++` (`:25-28`) |

**The split is required, not stylistic** (`RTC:41-43`, `Bridge:6-8`): the Swift
code says `import AvatarKitAgoraBridge`, and that only resolves against a
**separate Clang module**. As a subspec it would be folded into the same module
and the import would not resolve. The split also mirrors the SPM layout
(`Package.swift:22-32`, a separate target with `publicHeadersPath: "include"`).

**Why `EXCLUDED_ARCHS` is declared twice** (`podspec:26-33`): the main SDK's
simulator slice is arm64-only, and **xcconfig from a pod dependency does not
propagate to the dependent pod's target**. Without the local declaration, the
`AvatarKitRTC` target still builds for x86_64, fails to resolve the AvatarKit
module, and every public type reports "cannot find in scope". This only excludes
Intel Mac simulators, which the main SDK does not support anyway.

## Related

- Docs index → [`../README.md`](../README.md)
- Docs map → [`docs-map.md`](docs-map.md)
- Telemetry → [`telemetry-fields.md`](telemetry-fields.md)
- Tests → [`test-cases.md`](test-cases.md)
- Release → [`release-process.md`](release-process.md)
- Host SDK → `ios-sdk/docs/architecture/overview.md`
- Cross-platform counterpart → `avatarkit-android-rtc/docs/architecture/overview.md`
