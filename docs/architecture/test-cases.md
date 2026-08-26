# Test Cases — iOS RTC SDK

Layer: **current state** — rewritten in place whenever tests are added, removed
or renamed. Verified against the test sources on every release
(see the Documentation Alignment Gate section in this file).

Pods `AvatarKitRTC` + `AvatarKitAgoraBridge`, v1.0.0.

## 1. Two layers

| Layer | Where | Count |
|-------|-------|------:|
| SPM unit test | `AvatarKitRTC/Tests/AvatarKitRTCTests/` | **1 (smoke only)** |
| Demo integration — MOCK | `Demo/RTCDemo/Integration/Mock/MockTestCases.swift` | **43** |
| Demo integration — LIVE | `Demo/RTCDemo/Integration/TestCases.swift` | **20** |

The unit target has exactly one case, `testTypesAreImportable()`
(`AvatarKitRTCTests.swift:5`), whose body is `_ = RTCConnectionState.disconnected`.
Its own comment (`:6-7`) says it plainly: *"Smoke test: ensure the module
compiles and key public symbols are accessible. Real coverage lives in the demo
app."* **`xcodebuild test` reaches only this one case**, never the 63 below.

> Android RTC has no test target at all; iOS has one that is equivalent to zero
> behavioural coverage. Do not read it as "unit tested".

## 2. How to run

Both integration suites are **manual, inside the demo app**:

```
RTCDemoApp → "Integration Test" RTCDemoApp.swift:27-31
 → segmented picker: Mock (no network) / Live (Agora) IntegrationTestView.swift:82-88
 → fill Backend base URL / App ID / Avatar ID :90-108
 → Run → "Copy Report" (plain text to clipboard) :49-53
```

Default mode is **mock** (`:173`). Case selection is `switch mode` at `:196-200`.

> ⚠️ **"Mock (no network)" is only true of the RTC link.** The three credential
> fields gate *both* modes — the check sits before the `switch` (`:186-200`), and
> `TestRunner.run` still calls `AvatarSDK.initialize(appID:)` and
> `AvatarManager.load(id:)` for real (`TestRunner.swift:54-73`). Mock needs a
> valid appID/avatarID and network to load the avatar; it just never talks to
> Agora.

**LIVE additionally needs**: a reachable backend at `<baseURL>/api/agora-token`
(`TestRunner.swift:318-345`), the bundled `Demo/RTCDemo/Resources/test-audio.pcm`
(16 kHz/16-bit mono — **missing file degrades silently to empty `Data()`**,
`IntegrationTestView.swift:248-254`), a real device with microphone permission,
and patience: setup alone sleeps 5 s for egress (`TestRunner.swift:149-150`) and
one case has a 90 s timeout.

**Runner behaviour worth knowing** (`TestRunner.swift`): all cases share one
`AvatarPlayer` and run serially (`:9-11`, `:167`), with a fixed 1.5 s gap
(`:171-173`); a case that leaves the connection down triggers an automatic
`reconnect()` + 3 s sleep before the next (`:205-213`); and **a setup failure
short-circuits the whole run** — avatar load (`:70-78`), first token (`:100-109`)
or first connect (`:155-163`) failing yields a single synthetic `setup` FAIL and
returns, with no real case executed.

The report is **plain text** (`:265+`) copied to the clipboard by hand. There is
no JSON, no file output, and nothing a CI could consume.

## 3. Case identity and cross-SDK alignment

Ids are semantic dotted strings (`TestTypes.swift:8`), `rtc.<group>.<slug>` /
`mock.<group>.<slug>` — **not UUIDs**. The main SDKs use platform-registered
UUIDs; the RTC layer does not participate in that scheme.

| Suite | iOS | Android | Web |
|-------|----:|--------:|----:|
| Mock | **43** | **43** | 45 |
| Live | **20** | 17 | — |

Verified by sorting both sides' ids and diffing:

- **Mock: iOS ↔ Android is byte-identical across all 43.** ✅
- **Live: Android's 17 are a strict subset of iOS's 20.** The three extra are
 iOS-only, grouped under "iOS-Only" (`TestCases.swift:297-299`: *"Behavior that
 doesn't exist on web RTC SDK but is critical for iOS"*):

| id | Defined at |
|----|-----------|
| `rtc.ios.decode-invalid-frames` | `TestCases.swift:303` |
| `rtc.ios.avatar-id-mismatch` | `:319` |
| `rtc.ios.transition-end-smooth` | `:339` |

> ⚠️ **Two of those three do not test what their names say** — record this rather
> than trusting the titles:
>
> - `rtc.ios.avatar-id-mismatch` cannot construct a payload with an arbitrary
> avatar id from outside the SDK (`:324-328`), so it feeds empty `Data()` down
> the happy path; and its `catch` only logs (`:333-336`), so **it passes whether
> or not anything throws**.
> - `rtc.ios.transition-end-smooth` is a smoke check by its own admission
> (`:344-346`) — it asserts an empty payload is rejected (`:355`) and **never
> looks at whether the transition jumps**.

Android's `androidOnly` slot exists but is empty, so nothing flows the other way.

## 4. Status

**No case is statically skipped.** No `XCTSkip` anywhere, no commented-out
`TestCase(`. `TestStatus.skip` exists (`TestTypes.swift:18`) and is handled in
three places, but **nothing ever assigns it** — the skipped count in the report
is permanently zero.

Pass/fail is a runtime property; this document does not assert it, and there is
no checked-in baseline report to cite.

## 5. Mock suite (43)


### Mock: Idle (2 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Initial state — no frames, no stall | `mock.idle.fresh` | 3000 | `MockTestCases.swift:71` |
| Many idle packets in a row — idempotent | `mock.idle.repeated-idempotent` | 3000 | `MockTestCases.swift:78` |

### Mock: Speaking (4 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Animation without leading transition starts a session | `mock.seq.no-transition` | 8000 | `MockTestCases.swift:93` |
| transition-start + frames + transition-end | `mock.seq.with-transition` | 10000 | `MockTestCases.swift:102` |
| Long session — 50 sequential frames | `mock.seq.long-session` | 12000 | `MockTestCases.swift:115` |
| Frames with seq=nil bypass jitter buffer | `mock.seq.frameSeq-nil-direct-path` | 8000 | `MockTestCases.swift:123` |

### Mock: Transitions (5 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Repeated transition-start packets are idempotent | `mock.trans.start-then-start` | 6000 | `MockTestCases.swift:142` |
| transition-end without active session — ignored | `mock.trans.end-without-session` | 6000 | `MockTestCases.swift:158` |
| Repeated transition-end packets are idempotent | `mock.trans.end-then-end` | 8000 | `MockTestCases.swift:175` |
| transition-start arriving mid-playback is dropped | `mock.trans.late-start-during-playback` | 8000 | `MockTestCases.swift:188` |
| transition-start with no follow-up frames — no crash | `mock.trans.start-only-no-frames` | 5000 | `MockTestCases.swift:205` |

### Mock: Boundaries (4 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Session end with isEnd=true → idle marker | `mock.bound.anim-end-then-idle` | 6000 | `MockTestCases.swift:221` |
| Two back-to-back sessions both accumulate | `mock.bound.back-to-back` | 14000 | `MockTestCases.swift:231` |
| Hard idle without transition-end is accepted | `mock.bound.idle-skips-transition-end` | 6000 | `MockTestCases.swift:245` |
| Duplicate isStart=true mid-session is ignored | `mock.bound.duplicate-isStart` | 8000 | `MockTestCases.swift:253` |

### Mock: Jitter Buffer (7 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Perfectly in-order frames render in order | `mock.jb.ordering-in-order` | 8000 | `MockTestCases.swift:277` |
| Out-of-order frames are reordered by the buffer | `mock.jb.out-of-order` | 8000 | `MockTestCases.swift:289` |
| Duplicate seq does not render twice | `mock.jb.duplicate-seq` | 8000 | `MockTestCases.swift:304` |
| Sequence gap — buffer skips ahead | `mock.jb.gap` | 8000 | `MockTestCases.swift:319` |
| Older seq after newer is dropped | `mock.jb.regression-old-seq` | 8000 | `MockTestCases.swift:337` |
| Two frames is enough to enter draining | `mock.jb.tiny-burst` | 6000 | `MockTestCases.swift:356` |
| Buffer starves between frames then resumes | `mock.jb.starve-then-resume` | 10000 | `MockTestCases.swift:364` |

### Mock: Metadata (3 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| isRecovered=true bumps recovered counter | `mock.meta.isRecovered` | 6000 | `MockTestCases.swift:389` |
| isEnd=true on first frame is tolerated | `mock.meta.isEnd-without-isStart` | 5000 | `MockTestCases.swift:404` |
| Frame metadata isIdle=true is no-op for stats | `mock.meta.isIdle-flag` | 5000 | `MockTestCases.swift:416` |

### Mock: Stall (4 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| 5s without frames in a session fires .stalled | `mock.stall.5s-fires` | 12000 | `MockTestCases.swift:432` |
| Frame every second — no stall | `mock.stall.continuous-no-fire` | 12000 | `MockTestCases.swift:441` |
| Stall fires once per silent window, not repeatedly | `mock.stall.fires-once-not-repeatedly` | 15000 | `MockTestCases.swift:452` |
| Frames arriving after stall keep the session alive | `mock.stall.recover-after-stall` | 18000 | `MockTestCases.swift:463` |

### Mock: Events (4 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| connect sequence emits connecting → connected | `mock.evt.connect-events` | 5000 | `MockTestCases.swift:484` |
| disconnect emits .disconnected | `mock.evt.disconnect-event` | 5000 | `MockTestCases.swift:497` |
| Provider .error event reaches subscribers | `mock.evt.error-propagates` | 4000 | `MockTestCases.swift:508` |
| connectionChanged events reach subscribers | `mock.evt.connection-state-changed` | 4000 | `MockTestCases.swift:518` |

### Mock: Player Guards (6 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| connect() while already connected throws | `mock.guard.connect-when-connected` | 5000 | `MockTestCases.swift:537` |
| publishAudio() while disconnected throws | `mock.guard.publish-when-disconnected` | 6000 | `MockTestCases.swift:551` |
| publishExternalPCM() while disconnected throws | `mock.guard.publishExternal-when-disconnected` | 6000 | `MockTestCases.swift:565` |
| unpublishAudio() while not publishing is a no-op | `mock.guard.unpublish-idempotent` | 4000 | `MockTestCases.swift:579` |
| Double disconnect() is a no-op | `mock.guard.disconnect-idempotent` | 6000 | `MockTestCases.swift:587` |
| reconnect() with no prior config throws | `mock.guard.reconnect-without-history` | 4000 | `MockTestCases.swift:596` |

### Mock: Provider Lifecycle (3 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Provider error during connect surfaces to caller | `mock.life.connect-throws-propagates` | 8000 | `MockTestCases.swift:618` |
| Provider error during publishAudio surfaces | `mock.life.publish-throws-propagates` | 5000 | `MockTestCases.swift:633` |
| Reconnect after disconnect resets accumulated state | `mock.life.connect-disconnect-reset` | 12000 | `MockTestCases.swift:646` |

### Mock: Stream Stats (1 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Injected stream stats don't break playback | `mock.stats.simple-injection` | 6000 | `MockTestCases.swift:670` |

## 6. Live suite (20)


### Connection State (3 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Player is connected after setup | `rtc.conn.connected` | 5000 | `TestCases.swift:16` |
| Provider connection state is connected | `rtc.conn.provider-active` | 5000 | `TestCases.swift:25` |
| AvatarView is attached and idle is rendering | `rtc.conn.view-attached` | 8000 | `TestCases.swift:35` |

### Idle Animation (2 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Idle animation stream — no stall for 5s | `rtc.idle.no-stall-5s` | 10000 | `TestCases.swift:52` |
| Idle period — no animation frames pushed | `rtc.idle.no-frame-overrun` | 8000 | `TestCases.swift:65` |

### Audio Round-trip (2 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Push PCM — avatar responds with animation | `rtc.audio.push-pcm-and-frames` | 40000 | `TestCases.swift:90` |
| Two PCM sessions — each produces animation | `rtc.audio.multiple-sessions` | 90000 | `TestCases.swift:103` |

### Audio Publishing (3 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Publish and unpublish microphone | `rtc.pub.start-stop` | 10000 | `TestCases.swift:124` |
| Unpublish when not publishing — no crash | `rtc.pub.unpublish-when-idle` | 5000 | `TestCases.swift:136` |
| Publish while disconnected — throws notConnected | `rtc.pub.publish-while-disconnected` | 20000 | `TestCases.swift:145` |

### Stability (2 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Sustained connection — 15s without errors | `rtc.stab.sustained-15s` | 25000 | `TestCases.swift:176` |
| No false stall on healthy connection (8s) | `rtc.stab.no-false-stall` | 12000 | `TestCases.swift:191` |

### Disconnect & Reconnect (2 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Disconnect and reconnect | `rtc.rc.disconnect-reconnect` | 30000 | `TestCases.swift:207` |
| Connect to a fresh room/channel | `rtc.rc.new-room` | 30000 | `TestCases.swift:224` |

### Error Handling (3 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| Double disconnect — no crash | `rtc.err.double-disconnect` | 15000 | `TestCases.swift:250` |
| connect() while already connected — throws alreadyConnected | `rtc.err.connect-when-connected` | 5000 | `TestCases.swift:262` |
| Rapid publish/unpublish — no crash | `rtc.err.rapid-publish-cycle` | 15000 | `TestCases.swift:283` |

### iOS-Only (3 cases)

| Case | id | Timeout (ms) | Defined at |
|------|----|--------------|-----------|
| AvatarSDK.decodeAnimationFrames rejects garbage protobuf | `rtc.ios.decode-invalid-frames` | 5000 | `TestCases.swift:302` |
| decodeAnimationFrames rejects mismatched avatar id | `rtc.ios.avatar-id-mismatch` | 5000 | `TestCases.swift:318` |
| Conversation transition-end does not jump (smoke) | `rtc.ios.transition-end-smooth` | 8000 | `TestCases.swift:338` |

## 7. Adding a case

Append to the matching group in `MockTestCases.swift` (preferred — deterministic,
no Agora) or `TestCases.swift`. Ids follow the existing dotted convention.

**If the case also exists on Android, reuse its exact id** — that string is the
only thing holding the two suites together, since RTC cases have no platform
registry. Check `avatarkit-android-rtc/demo/.../integration/` first.

Then update this file in the same commit
.

## Related

- Docs index → [`../README.md`](../README.md)
- Docs map → [`docs-map.md`](docs-map.md)
- Architecture → [`overview.md`](overview.md)
- Release → [`release-process.md`](release-process.md)
