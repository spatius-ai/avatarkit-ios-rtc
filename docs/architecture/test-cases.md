# Test Cases — iOS RTC SDK

Layer: **current state** — rewritten in place whenever tests are added, removed
or renamed. Verified against the test sources on every release
(see [`release-process.md`](release-process.md) §5, documentation alignment gate).

Case counts are deliberately not written anywhere in this file: hand-written
counts were the main source of drift. The catalog in §2 is the list, and
`scripts/check-docs.sh` checks it against the code.

## 1. Unit tests

| | |
|---|---|
| Command | `scripts/run-unit-tests.sh` — prints `executed=<n> failed=<n>`; that output is authoritative |
| Files | `AvatarKitRTC/Tests/AvatarKitRTCTests/AvatarKitRTCTests.swift`, `ConversationStateTests.swift` |
| Framework | XCTest, SPM test target `AvatarKitRTCTests` (`Package.swift`) |

Coverage:

- `AvatarKitRTCTests.testTypesAreImportable()` — smoke check that the public
  module links (`_ = RTCConnectionState.disconnected`).
- `ConversationStateTests` drives `AnimationHandler` directly against a fake
  `AvatarRendererAdapter` and pins the render-level conversation-state edge:
  `.speaking` exactly once on the first rendered frame (start transition,
  buffered stream, or direct path), `.idle` exactly once when the end transition
  has played out or `startIdle()` runs while speaking, nothing when already idle
  or at construction, and a silent reset on `dispose()` so the next round after a
  reconnect edges again. `AvatarPlayer` itself cannot be constructed there
  (`AvatarView` needs a loaded `Avatar`), so the player-level getter is covered by
  `mock.evt.conversation-state` in §2.

Why a script and not `xcodebuild test`: the test bundle only loads after the
Agora / AvatarKit binary frameworks copied next to it are ad-hoc signed
(`Library not loaded: @rpath/AgoraRtcKit.framework … Trying to load an unsigned
library`), and `swift test` targets macOS, which Agora does not ship. The script
does build-for-testing → `codesign --sign -` → test-without-building on an
automatically picked iPhone simulator (`SIMULATOR_ID=<udid>` overrides).

The unit target never reaches the integration suites below — those run inside
the demo app.

## 2. MOCK integration suite (release gate)

**Entry point** (demo app `Demo/RTCDemo`, scheme `RTCDemo`):

```
RTCDemoApp → "Integration Test"                      RTCDemoApp.swift:27-31
  → segmented picker: Mock (no network) / Live (Agora)  IntegrationTestView.swift:82-88
  → fill Backend base URL / App ID / Avatar ID          IntegrationTestView.swift:90-108
  → Run Mock → "Copy Report"                            IntegrationTestView.swift:36-53
```

Default mode is **Mock** (`IntegrationTestView.swift:173`); `switch mode` at
`IntegrationTestView.swift:196-200` picks `MockTestCases.all` or `TestCases.all`.

**Prerequisites.** "Mock (no network)" is only true of the RTC link. The three
fields gate both modes (`IntegrationTestView.swift:184-189`), and
`TestRunner.run` still calls `AvatarSDK.initialize(appID:)` and
`AvatarManager.load(id:)` for real (`TestRunner.swift:56-81`). MOCK therefore needs
a valid App ID / Avatar ID and network to load the avatar; it never talks to
Agora (`MockRTCProvider` injects every packet). The Backend base URL is not called
in MOCK mode but must be non-empty. Runs on a device or an arm64 simulator.

**Runner behaviour** (`TestRunner.swift`): all cases share one `AvatarPlayer`
and run serially with a fixed 1.5 s gap (`TestRunner.swift:169-174`); a case that
leaves the connection down triggers `reconnect()` + 3 s sleep before the next
(`TestRunner.swift:207-216`); a setup failure (avatar load, first token, first
connect) yields a single synthetic `setup` FAIL and no real case runs.
`TestStatus.skip` exists (`TestTypes.swift:18`) but nothing assigns it.

**Report.** "Copy Report" puts plain text on the clipboard
(`TestRunner.generateReport`, `TestRunner.swift:277`). The layout is identical on
web, Android and iOS:

```
AvatarKitRTC Integration Report — MOCK
Platform: iOS
RTC SDK: <AvatarKitRTC version>
Main SDK: <AvatarSDK.version at runtime>
Date: <ISO-8601 UTC>
Device: <model (hardware identifier)>
OS: iOS <version>

--- <group> ---
[PASS] mock.idle.fresh — Initial state — no frames, no stall (0.1s)
[FAIL] mock.jb.gap — Sequence gap — buffer skips ahead (2.0s)
  <error text>
  logs: <only on failure>
...

Result: <passed>/<total> passed[, <n> failed][, <n> skipped]
Failed: <failed case ids, comma-separated>   ← only when something failed
```

`RTC SDK` comes from `TestRunner.rtcSDKVersion` (`TestRunner.swift:273`), a
mirror of the library's internal `TelemetryIdentity.sdkVersion` — the library
exposes no public version constant, and SPM cannot inject one.
`scripts/check-release.sh` fails when the two differ. `Main SDK` is the public
`AvatarSDK.version`.

**Gate:** every MOCK case must PASS. The `Result` line and the device go into the
release execution summary (`release-process.md` §6.1).

### Catalog

Shared by the three RTC repos and **byte-identical** in each
(`scripts/check-docs.sh` compares them when the sibling repos are checked out).
Ids, groups and order are authoritative; the ✅ ids in the `ios` column must equal
`MockTestCases.all` (`Demo/RTCDemo/Integration/Mock/MockTestCases.swift`) in the
same order. The catalog is changed for all three repos at once, never here alone.

<!-- mock-catalog:begin -->
| # | id | group | scenario | web | android | ios |
|---|----|-------|----------|-----|---------|-----|
| 1 | `mock.idle.fresh` | Mock: Idle | Initial state — no frames, no stall | ✅ | ✅ | ✅ |
| 2 | `mock.idle.repeated-idempotent` | Mock: Idle | Many idle packets in a row — idempotent | ✅ | ✅ | ✅ |
| 3 | `mock.seq.no-transition` | Mock: Speaking | Animation without leading transition starts a session | ✅ | ✅ | ✅ |
| 4 | `mock.seq.with-transition` | Mock: Speaking | transition-start + frames + transition-end | ✅ | ✅ | ✅ |
| 5 | `mock.seq.long-session` | Mock: Speaking | Long session — 50 sequential frames | ✅ | ✅ | ✅ |
| 6 | `mock.seq.frameSeq-nil-direct-path` | Mock: Speaking | Frames with seq=nil bypass jitter buffer | ✅ | ✅ | ✅ |
| 7 | `mock.trans.start-then-start` | Mock: Transitions | Repeated transition-start packets are idempotent | ✅ | ✅ | ✅ |
| 8 | `mock.trans.end-without-session` | Mock: Transitions | transition-end without active session — ignored | ✅ | ✅ | ✅ |
| 9 | `mock.trans.end-then-end` | Mock: Transitions | Repeated transition-end packets are idempotent | ✅ | ✅ | ✅ |
| 10 | `mock.trans.late-start-during-playback` | Mock: Transitions | transition-start arriving mid-playback is dropped | ✅ | ✅ | ✅ |
| 11 | `mock.trans.start-only-no-frames` | Mock: Transitions | transition-start with no follow-up frames — no crash | ✅ | ✅ | ✅ |
| 12 | `mock.bound.anim-end-then-idle` | Mock: Boundaries | Session end with isEnd=true → idle marker | ✅ | ✅ | ✅ |
| 13 | `mock.bound.back-to-back` | Mock: Boundaries | Two back-to-back sessions both accumulate | ✅ | ✅ | ✅ |
| 14 | `mock.bound.idle-skips-transition-end` | Mock: Boundaries | Hard idle without transition-end is accepted | ✅ | ✅ | ✅ |
| 15 | `mock.bound.duplicate-isStart` | Mock: Boundaries | Duplicate isStart=true mid-session is ignored | ✅ | ✅ | ✅ |
| 16 | `mock.jb.ordering-in-order` | Mock: Jitter Buffer | Perfectly in-order frames render in order | ✅ | ✅ | ✅ |
| 17 | `mock.jb.out-of-order` | Mock: Jitter Buffer | Out-of-order frames are reordered by the buffer | ✅ | ✅ | ✅ |
| 18 | `mock.jb.duplicate-seq` | Mock: Jitter Buffer | Duplicate seq does not render twice | ✅ | ✅ | ✅ |
| 19 | `mock.jb.gap` | Mock: Jitter Buffer | Sequence gap — buffer skips ahead | ✅ | ✅ | ✅ |
| 20 | `mock.jb.regression-old-seq` | Mock: Jitter Buffer | Older seq after newer is dropped | ✅ | ✅ | ✅ |
| 21 | `mock.jb.tiny-burst` | Mock: Jitter Buffer | Two frames is enough to enter draining | ✅ | ✅ | ✅ |
| 22 | `mock.jb.starve-then-resume` | Mock: Jitter Buffer | Buffer starves between frames then resumes | ✅ | ✅ | ✅ |
| 23 | `mock.meta.isRecovered` | Mock: Metadata | isRecovered=true bumps recovered counter | ✅ | ✅ | ✅ |
| 24 | `mock.meta.isEnd-without-isStart` | Mock: Metadata | isEnd=true on first frame is tolerated | ✅ | ✅ | ✅ |
| 25 | `mock.meta.isIdle-flag` | Mock: Metadata | Frame metadata isIdle=true is no-op for stats | ✅ | ✅ | ✅ |
| 26 | `mock.stall.5s-fires` | Mock: Stall | 5s without frames in a session fires .stalled | ✅ | ✅ | ✅ |
| 27 | `mock.stall.continuous-no-fire` | Mock: Stall | Frame every second — no stall | ✅ | ✅ | ✅ |
| 28 | `mock.stall.fires-once-not-repeatedly` | Mock: Stall | Stall fires once per silent window, not repeatedly | ✅ | ✅ | ✅ |
| 29 | `mock.stall.recover-after-stall` | Mock: Stall | Frames arriving after stall keep the session alive | ✅ | ✅ | ✅ |
| 30 | `mock.evt.connect-events` | Mock: Events | connect sequence emits connecting → connected | ✅ | ✅ | ✅ |
| 31 | `mock.evt.disconnect-event` | Mock: Events | disconnect emits .disconnected | ✅ | ✅ | ✅ |
| 32 | `mock.evt.error-propagates` | Mock: Events | Provider .error event reaches subscribers | ✅ | ✅ | ✅ |
| 33 | `mock.evt.connection-state-changed` | Mock: Events | connectionChanged events reach subscribers | ✅ | ✅ | ✅ |
| 34 | `mock.evt.conversation-state` | Mock: Events | conversationStateChanged: speaking once, idle once, getter tracks | ✅ | ✅ | ✅ |
| 35 | `mock.guard.connect-when-connected` | Mock: Player Guards | connect() while already connected throws | ✅ | ✅ | ✅ |
| 36 | `mock.guard.publish-when-disconnected` | Mock: Player Guards | publishAudio() while disconnected throws | ✅ | ✅ | ✅ |
| 37 | `mock.guard.publishExternal-when-disconnected` | Mock: Player Guards | publishExternalPCM() while disconnected throws | n/a¹ | ✅ | ✅ |
| 38 | `mock.guard.unpublish-idempotent` | Mock: Player Guards | unpublishAudio() while not publishing is a no-op | ✅ | ✅ | ✅ |
| 39 | `mock.guard.disconnect-idempotent` | Mock: Player Guards | Double disconnect() is a no-op | ✅ | ✅ | ✅ |
| 40 | `mock.guard.reconnect-without-history` | Mock: Player Guards | reconnect() with no prior config throws | ✅ | ✅ | ✅ |
| 41 | `mock.life.connect-throws-propagates` | Mock: Provider Lifecycle | Provider error during connect surfaces to caller | ✅ | ✅ | ✅ |
| 42 | `mock.life.publish-throws-propagates` | Mock: Provider Lifecycle | Provider error during publishAudio surfaces | ✅ | ✅ | ✅ |
| 43 | `mock.life.connect-disconnect-reset` | Mock: Provider Lifecycle | Reconnect after disconnect resets accumulated state | ✅ | ✅ | ✅ |
| 44 | `mock.stats.simple-injection` | Mock: Stream Stats | Injected stream stats don't break playback | ✅ | ✅ | ✅ |

¹ web `AvatarPlayer` has no `publishExternalPCM()`.
<!-- mock-catalog:end -->

## 3. LIVE suite (optional, not a release gate)

`Demo/RTCDemo/Integration/TestCases.swift`, picker "Live (Agora)". Talks to a
real Agora channel, so results depend on the network and the backend; it is kept
for smoke coverage and **does not gate a release**. Run it when a change touches
the Agora path; a LIVE failure is investigated, not a blocker by itself.

**Prerequisites** beyond MOCK's: a reachable backend serving
`<baseURL>/api/agora-token` (`DemoBackend.fetchToken` in `TestRunner.swift`),
the bundled `Demo/RTCDemo/Resources/test-audio.pcm` (16 kHz / 16-bit mono — a
missing file silently degrades to empty `Data()`,
`IntegrationTestView.swift:248-254`), a real device with microphone permission,
and time: setup alone sleeps 5 s for egress (`TestRunner.swift:152-153`) and one
case has a 90 s timeout. The report is the same format with `— LIVE` in the title.

| id | group | case |
|----|-------|------|
| `rtc.conn.connected` | Connection State | Player is connected after setup |
| `rtc.conn.provider-active` | Connection State | Provider connection state is connected |
| `rtc.conn.view-attached` | Connection State | AvatarView is attached and idle is rendering |
| `rtc.idle.no-stall-5s` | Idle Animation | Idle animation stream — no stall for 5s |
| `rtc.idle.no-frame-overrun` | Idle Animation | Idle period — no animation frames pushed |
| `rtc.audio.push-pcm-and-frames` | Audio Round-trip | Push PCM — avatar responds with animation |
| `rtc.audio.multiple-sessions` | Audio Round-trip | Two PCM sessions — each produces animation |
| `rtc.pub.start-stop` | Audio Publishing | Publish and unpublish microphone |
| `rtc.pub.unpublish-when-idle` | Audio Publishing | Unpublish when not publishing — no crash |
| `rtc.pub.publish-while-disconnected` | Audio Publishing | Publish while disconnected — throws notConnected |
| `rtc.stab.sustained-15s` | Stability | Sustained connection — 15s without errors |
| `rtc.stab.no-false-stall` | Stability | No false stall on healthy connection (8s) |
| `rtc.rc.disconnect-reconnect` | Disconnect & Reconnect | Disconnect and reconnect |
| `rtc.rc.new-room` | Disconnect & Reconnect | Connect to a fresh room/channel |
| `rtc.err.double-disconnect` | Error Handling | Double disconnect — no crash |
| `rtc.err.connect-when-connected` | Error Handling | connect() while already connected — throws alreadyConnected |
| `rtc.err.rapid-publish-cycle` | Error Handling | Rapid publish/unpublish — no crash |
| `rtc.ios.decode-invalid-frames` | iOS-Only | AvatarSDK.decodeAnimationFrames rejects garbage protobuf |
| `rtc.ios.avatar-id-mismatch` | iOS-Only | decodeAnimationFrames rejects mismatched avatar id |
| `rtc.ios.transition-end-smooth` | iOS-Only | Conversation transition-end does not jump (smoke) |

### The three `rtc.ios.*` cases

They live in the `iOSOnly` group (`TestCases.swift:297-301`) and have no
counterpart on Android or web, because they do not test RTC behaviour: they call
main-SDK APIs directly — `AvatarSDK.decodeAnimationFrames(from:)` and
`AvatarView.generateTransitionToFrame(_:frameCount:)`. That is also why they are
not in the MOCK catalog. Two of them do less than their names say:

- `rtc.ios.avatar-id-mismatch` cannot build a payload with an arbitrary avatar id
  from outside the SDK, so it feeds empty `Data()` down the happy path, and its
  `catch` only logs — **it passes whether or not anything throws**.
- `rtc.ios.transition-end-smooth` is a smoke check by its own comment: it asserts
  that an empty payload is rejected and **never looks at whether the transition
  jumps**.

## 4. Cross-SDK differences outside the catalog

- **LIVE**: Android's LIVE ids are exactly iOS's minus the three `rtc.ios.*`
  cases (verified by diffing the id sets); Android's own platform-only group is
  empty. Web has no LIVE suite.
- **Unit tests** are not aligned across platforms and are not part of the
  catalog: iOS has the XCTest target above, Android has JVM unit tests under
  `sdk/src/test`, web has its own vitest suite. Each repo's `test-cases.md` §1
  describes its own.
- **Ids** are semantic dotted strings (`mock.<group>.<slug>`,
  `rtc.<group>.<slug>`), not the platform-registered UUIDs the main SDKs use. The
  id string is the only thing tying a case to its counterparts.

## 5. Adding a case

1. MOCK (preferred — deterministic, no Agora): the catalog changes first, for all
   three repos at once; then add the case to the matching group in
   `MockTestCases.swift` with exactly the catalog id and group, in catalog order.
   `scripts/check-docs.sh` fails until code and catalog agree.
2. LIVE: append to the matching group in `TestCases.swift`. If Android has the
   case, reuse its exact id. Update the table in §3 in the same commit.

## Related

- Docs index → [`../README.md`](../README.md)
- Docs map → [`docs-map.md`](docs-map.md)
- Architecture → [`overview.md`](overview.md)
- Release → [`release-process.md`](release-process.md)
