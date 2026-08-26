# Telemetry Fields — iOS RTC SDK

Layer: **current state** — describes what `AvatarKitRTC` **actually emits at
HEAD** (v1.0.0). Rewritten in place whenever an event or field changes;
re-verified against the telemetry call sites on every release
(→ `knowledge/workflows/release-workflow.md` §1.1).

See `knowledge/telemetry-events.md` (umbrella repo) for the cross-platform event catalog — that catalog has no `rtc_*` entries yet.

Paths are relative to `AvatarKitRTC/Sources/AvatarKitRTC/`; host SDK paths are marked `ios-sdk/AvatarKit/Sources/AvatarKit/`.

## 0. Relationship to the Host SDK

This library **creates no OTel provider of its own**; everything rides on the pipeline the host SDK has already initialized. The only exit point is
`@_spi(RTC) public enum RTCTelemetry` (`ios-sdk/…/Utils/Tracker.swift:32`).

| Channel | Entry point (this library) | Entry point (host SDK) | Destination |
|------|---------|---------|------|
| event / log | `Telemetry.event` (`Utils/Telemetry.swift:45,62`) | `RTCTelemetry.track` (`Tracker.swift:54`) | `trackDirect` → dual-sent to OtelLogger + PostHog |
| metric | `Telemetry.recordMetric` (`Telemetry.swift:87,105`) | `RTCTelemetry.metric` (`Tracker.swift:84`) | `logMetric` → OTel metrics + one OTel log, **not sent to PostHog** |
| trace | `Telemetry.startPlaybackTrace` (`Telemetry.swift:113,130`) | `RTCTelemetry.startPlaybackTrace` (`Tracker.swift:148`) | `OtelTrace.startPlaybackTrace` |
| traceparent | `AnimationHandler.swift:327` | `RTCTelemetry.peekTraceparent` (`Tracker.swift:179`) | **full protobuf decode** (`:180`) |

The dirty-flag mechanism exists here too (`ios-sdk/…/OtelMetrics.swift:275` `hasBusinessMetric`,
and `OtelExportObserver.swift:178` skips the entire export round when it is false) — the same mechanism as web/android;
iOS also satisfies it passively (RTC has no access to the host SDK's meter).

### Identity claim — iOS is the only one of the three platforms with a recovery path

`TelemetryIdentity.claim()` (`Utils/TelemetryIdentity.swift:27-32`) injects
`sdk_package = "spatius-ios-rtc"` and `sdk_version`; the call site is `AvatarPlayer.init`
(`AvatarPlayer.swift:141`) — **claimed during construction**, not via a module side effect or a ContentProvider.

**Why construction time is early enough** (`TelemetryIdentity.swift:11-17`, verified): the iOS OTel
Resource is built **inside the `Task.detached` spawned by** `AvatarSDK.initialize()`, after region
resolution (`ios-sdk/AvatarSDK.swift:400` → `:412-418`), not synchronously within the call.
So a claim made while constructing `AvatarPlayer` still gets there first. Android has no such window (its Resource is built
synchronously), which is why it needs a ContentProvider.

> **A fallback unique to iOS**: when `AvatarSDK.inject` (`:125-138`) detects a changed value it calls
> `rebuildTelemetryResourceIfNeeded()` (`:145-155`) — if already initialized, it calls
> `shutdown()` (flushing first) and rebuilds all three providers. **Neither web nor android has this recovery**,
> so a late claim is simply lost there.

> ⚠️ **`TelemetryIdentity.sdkVersion` is a hand-written constant, and it has already drifted twice.**
>
> Swift Package Manager has no build-time substitution: a package cannot read its own podspec or git tag.
> Compare web (vite `define` ← package.json) and android (`BuildConfig` ←
> `gradle.properties`) — **both are automatic; only iOS has no automatic source**, so the constant
> itself is the single source of truth.
>
> The two drifts: the constant stayed at beta.6 for the whole beta.7 cycle (fixed in `dc3aee9`); and **after the v1.0.0 release it stayed at
> `1.0.0-beta.9`, meaning every record reported by v1.0.0 carried a version number that was never released**.
> Keep this in mind when analyzing data from that version — the already-published v1.0.0 artifact cannot be retroactively corrected.
>
> `scripts/check_version_consistency.sh` now guards against this (comparing the constant against both podspecs and
> failing on any mismatch), and is wired into the release process.
> → [`release-process.md`](release-process.md) §2

**Resource under an RTC integration**: `service.name = avatarkit`, `sdk.package = spatius-ios-rtc`,
`sdk.version` = this library's version, `sdk.platform = ios`, `render_sdk_version` = host SDK version,
plus `app_id` / `region` / `dsm`.

### Hard check on driving mode (unique among the three platforms)

`assertRtcMode()` at `AvatarPlayer.swift:118-131` — if `drivingServiceMode != .rtc` it calls
`preconditionFailure` outright, **trapping even in release builds**. Rationale (`:101-118`): the mode is the `dsm` on every
record; get it wrong and the whole session's data cannot be classified, with no way to fix it afterwards. Android throws a catchable
exception; web has no such check.

### conversation_id

`Utils/ConversationId.swift:9-14`: on the RTC path the server **never sends** a conversation id, so one is
generated locally as `YYYYMMDDHHmmss_<12-char NanoID>`, **deliberately not impersonating a server-issued id**.
Generated at `AnimationHandler.swift:622`, cleared at `:841`.

### Diagnostic tools

`TelemetryRecorder` (off by default, `:32`) **mirrors all four channels** — event, metric marker,
recordMetric, and trace. On par with android; web mirrors only 2 channels.
Labels are recorded with their **native JSON types** (`Telemetry.swift:99-102`); the comment explains this is so you can tell
from the file whether a label was stringified at the exit point.

`PlaybackProbe` (off by default, `:19`) — frame-to-screen CSV, demo use only.

## 1. Metric Channel — 16 metrics

All go through `Telemetry.recordMetric` (`Telemetry.swift:87`), which automatically adds
`service_module = "rtc"` (`:93`).

### 1.1 Playback quality — 12 metrics (once per round)

`AnimationHandler.recordPlaybackMetrics` (`:853-892`), labels
`{provider, end_reason}` (`:862-865`).

| metric | value source | location |
|--------|-----------|------|
| `rtc_playback_duration_ms` | `nowMs() - conversationStartTime` | `:867` |
| `rtc_playback_avg_fps` | **arithmetic mean of fps samples, rounded** (`:735-736`) | `:868` |
| `rtc_playback_frame_count` | `conversationFrameCount` | `:869` |
| `rtc_playback_skipped_frames` | `conversationSkipped` | `:870` |
| `rtc_playback_skip_rate_pct` | `skipped/(frameCount+lost)` | `:871` |
| `rtc_playback_stall_count` | `quality.stalls.count` | `:872` |
| `rtc_playback_stall_total_ms` | sum of stall durations | `:873` |
| `rtc_playback_stall_max_ms` | longest stall | `:874` |
| `rtc_playback_stall_rate_pct` | `stallTotal/duration` | `:878` |
| `rtc_playback_tail_discarded` | `quality.tailDiscarded` | `:879` |
| `rtc_playback_start_transition_missing` | `max(0, expected - rendered)` | `:882-886` |
| `rtc_playback_end_transition_missing` | same as above | `:887-891` |

> The `avg_fps` definition **matches android** (the mean of per-second fps readings), and differs from web's
> "frames / speakingMs" — **the two mobile platforms agree; web is the outlier**.

### 1.2 Transport layer — 4 metrics

`AvatarPlayer.sampleTransportStats` (`:552-600`), labels are only `{provider}`.

| metric | value | location | notes |
|--------|-------|------|------|
| `rtc_transport_rtp_packets_lost` | cumulative delta | `:574` | **Never reported under Agora** (the provider does not populate `packetsLost`) |
| `rtc_transport_rtp_loss_rate_pct` | supplied directly by the provider | `:592` | the delta fallback branch is never entered |
| `rtc_transport_rtt_ms` | `read.rttMs` | `:595` | |
| `rtc_transport_jitter_ms` | `read.jitterMs` | `:598` | **Has a value on iOS** (same as android; web's Agora does not) |

Sampling timing: **once at the start and once at the end of each playback round** (`:478` / `:483`); the baseline is taken only once and carried across rounds
(`:534-546`). Same change as android `e977af6` and web `d8b310b`.

> ⚠️ **Buckets for these 4 metrics have landed in the host SDK, but take effect only after the host SDK ships.**
> `bucketProfiles` in `ios-sdk/…/OtelMetrics.swift` previously covered only the 12
> `rtc_playback_*` metrics, so these 4 matched nothing and fell into OTel's default buckets, which have no resolution for
> RTT milliseconds or percentages.
> They have been filled in following the web host SDK's tiers (`c886419`), and the android host SDK was updated to match (`28ff8c8`).
>
> Views can only be configured by whoever builds the MeterProvider (comment at `OtelMetrics.swift:94-96`),
> so **until the host SDK ships a release containing that change and this repo bumps its dependency, production data still lands in the default buckets**.

### 1.3 Four metrics that were removed (`2d28046`)

`rtc_transport_packets_lost` / `_recovered` / `_dropped` / `_out_of_order` have been removed, with a
tombstone comment left at the deletion site (`AvatarPlayer.swift:625-631`).

Root cause: when `Providers/SEIPacketParser.swift:265-274` constructs `RTCStreamStats` it hardcodes the five packet-loss
fields to 0 and `lastRenderedSeq` to -1 — identical to android
`SEIPacketParser.kt:264-274` and web `SEIExtractor.ts:474-479`.

| | web-rtc | android-rtc | ios-rtc |
|---|---|---|---|
| the 4 `packets_*` metrics | **kept** (documented as never firing) | **removed** | **removed** ✅ matches android |

`rtc_stream_stats_anomaly` is kept on all three platforms (it has a non-zero guard, `AvatarPlayer.swift:632-633`).

> ⚠️ **Knock-on effect**: in `rtc_session_summary`, `stream_frames_lost` / `_recovered` /
> `_dropped` / `_out_of_order` / `_duplicate` are **always 0** under Agora, and
> `last_rendered_seq` is always -1. **That means "not measurable", not "a flawless link".**

## 2. Log Channel — 16 events + 3 markers

### 2.1 Field types — iOS preserves native types

`Telemetry.event` takes `[String: Sendable]` (`:48`); the host SDK signature is likewise
`[String: Sendable]` (`Tracker.swift:57`), and `OtelLogger.track` uses `toLogValues`
to convert into a type-preserving `LogValue` (`OtelLogger.swift:122-125`, whose comment explicitly says it "matches web's
toAnyValue: bool/number reported natively").

Metric labels preserve types too: `Telemetry.Label` (`:17-43`) → `RTCTelemetry.LabelValue`
→ `LogValue`, with all four cases surviving end to end without downgrade.

> ✅ **Android's "every field on the log channel gets stringified" defect does not exist on iOS** —
> `avg_fps`, `stall_total_ms`, and `tail_intact` keep their native types in iOS logs. This is one area where iOS
> is better than android.

Common fields come from the host SDK's `Tracker.trackDirect`; the PostHog channel additionally carries
`timestamp`/`server_timestamp` (calibrated through ClockSync), while OtelLogger uniformly adds
`connection_id` and buffers-and-replays events emitted before calibration. **The web defect where `app_id`/`env` are always empty strings
does not apply here.** PostHog is disabled in `cn-*` regions.

### 2.2 Connection lifecycle (`AvatarPlayer.swift`)

| event | level | trigger | fields | location |
|------|-------|------|------|------|
| `rtc_connect_start` | info | entry to `connect()` | `provider` | `:180` |
| `rtc_connect_success` | info | connected | `provider`, `duration` | `:192` |
| `rtc_connect_failed` | error | failure | `provider`, **`reason`**, `duration` | `:197` |
| `rtc_attach_start` | info | entry to route B | `provider` | `:232` |
| `rtc_attach_success` | info | attach succeeded | `provider` | `:245` |
| `rtc_attach_failed` | error | attach failed | `provider`, **`reason`** | `:247` |
| `rtc_detached` | info | `detach()` | `provider` | `:265` |
| `rtc_session_summary` | info | `disconnect()` | see §2.3 | `:299` |
| `rtc_disconnected` | info | immediately after summary | `provider`, `session_duration` | `:328` |
| `rtc_audio_publish_failed` | error | publish failed | `provider`, **`description`** | `:339` / `:365` |
| `rtc_reconnect_start` | info | entry to `reconnect()` | `provider` | `:394` |
| `rtc_reconnect_success` | info | reconnect succeeded | `provider`, `duration` | `:401` |
| `rtc_reconnect_failed` | error | reconnect failed | `provider`, **`reason`** | `:407` |
| `rtc_error` | error | provider error | `provider`, **`description`** | `:449` |
| `rtc_stream_stalled` | warning | 5s without a frame | `provider`, `session_elapsed` | `:509` |
| `rtc_playback_stats` | info | once per round | see §2.4 | `AnimationHandler.swift:775` |

> **Inconsistent field naming, same as android**: the three failed events for connect / attach / reconnect use
> `reason`, while audio_publish / error use `description`.
>
> **`rtc_stream_stalled` does not carry `conversation_id`** (web does).
>
> iOS has `rtc_attach_*` / `rtc_detached` (same as android, corresponding to route B); it has no
> `rtc_worker_failed` (no LiveKit).

### 2.3 `rtc_session_summary` — 27 fields (`:299-327`)

`provider`, `total_duration_ms`, `total_frames`, `total_lost`, `total_recovered`,
`total_dropped`, `avg_fps`, `stall_count`, `reconnect_count`, `conversation_count`,
`stream_stats_samples`, `stream_avg_fps`, `stream_max_fps`, `stream_frames_lost`,
`stream_frames_recovered`, `stream_frames_dropped`, `stream_frames_out_of_order`,
`stream_frames_duplicate`, plus 9 `jitter_*` fields.

**Field-for-field identical to android.** The same four semantic divergences from web apply:
① there is a session-level `avg_fps` (web explicitly documents that it is "deliberately omitted"); ② it uses `frames` rather than `packets`;
③ the 9 `jitter_*` fields are in the payload (web explicitly documents that they "never enter any telemetry payload");
④ **there is no `end_reason` field** (web has one with four values).

### 2.4 `rtc_playback_stats` — 37 fields (`AnimationHandler.swift:775-813`)

Guard at `:730-732` (frame count > 0, or any jitter counter non-zero).

`stall_events` / `skipped_seqs` are **hand-assembled JSON strings** (`:760-773`) — the log backend
flattens nested structures and rejects arrays of objects. Elements of the former are `{seq, ms, ticks, starved}`; the latter are `"12"` or
`"12-15"`.

> 🔴 **Does not carry `conversation_id`** (exactly as on android). Yet the trace's trace_id is derived from
> it — the host SDK comment (`Tracker.swift:136-138`) says this id exists precisely "so a trace can
> be found from the matching `rtc_playback_stats` event", and **iOS cannot deliver on that either**.

`EndReason` declares five values (`:74-80`), but there are only two assignment sites (`:458` / `:536`),
so **`.disconnect` is never assigned** — the same dead value as web/android.

### 2.5 Marker metrics

`Telemetry.metric` (`:65-75`) adds `telemetry_kind = "metric"` (`:70`) and then goes through
`RTCTelemetry.track(.info, …)`.

| name | trigger | location |
|------|------|------|
| `rtc_stream_stats_anomaly` | any delta > 0 in the sampling window | `AvatarPlayer.swift:634-645` |
| `rtc_jitter_buffer_starved` | entering STARVED, **edge-triggered** (`:1507`) | `AnimationHandler.swift:1509` |
| **`rtc_jitter_buffer_overflow`** | buffer exceeded `bufferMaxSize = 4`, oldest frame evicted | `AnimationHandler.swift:1046` |

> **Two divergences from web, same as android**: `rtc_jitter_buffer_overflow` **still exists on iOS**
> (web removed it in `d8b310b`), and `rtc_jitter_buffer_starved` is **edge-triggered** (web fires at most
> once per round). Neither carries `conversation_id`.
>
> ✅ **`telemetry_kind` is a real field on iOS** (actually written at `Telemetry.swift:70`).
> On android it exists only in a comment, not in the implementation — **iOS is the only one of the three platforms that actually implements it**.

## 3. Trace

### 3.1 Span tree (`AnimationHandler.emitPlaybackTrace`, `:901-1007`)

Root span attrs `{provider, end_reason}` (`:911-914`).
`start_transition` (`:922-931`, marked error when `rendered < expected`) →
alternating `playing_N` / `stall_N` (`:941-962`, stalls are **always marked error**) → a closing `playing_N`
→ `end_transition` (`:968-979`) → `skip_N` **zero-width markers** (`:983-994`, always marked error).
`trace.end` attrs: `frame_count`, `skipped_frames`, `stall_count`,
`stall_total_ms`, `tail_intact`, `duration_ms`.

Structurally one-to-one with web/android; the root always closes OK.

> ⚠️ **iOS has no try/catch wrapper like android's.** Android's `emitPlaybackTrace`
> is wrapped in a try/catch as a whole (comment: "Never let telemetry break playback"), whereas the Swift side runs unguarded
> (`:901-1007`) — an iOS-only TODO.

> ⚠️ **Trace wall clock is not ClockSync-calibrated**: `AnimationHandler.swift:1553-1554` uses a bare
> `Date()`, and the host SDK's `OtelTrace.swift` mentions ClockSync nowhere. The log channel, by contrast, is calibrated
> (`OtelLogger.swift:126,147`) — **the same timeline misalignment issue as android**; web is calibrated.

### 3.2 Continuing the server-side trace in reverse (`da9e828`)

Same design as web `bc4732b` and android `f3cb8ef`, with the same three key points:

1. **Retry each round until one is obtained, rather than only inspecting the first packet** — `AnimationHandler.swift:326-328`; the comment
   (`:322-325`) states explicitly that a round may open with a frame the server did not tag, so trying only once would lose the trace for the whole round.
   It stops once one is obtained, so in steady state it decodes once per round
2. **Cleared every round** — `:842`
3. **Falls back** to the host SDK's trace_id derived from conversationId (`OtelTrace.swift:346-348`)

> ⚠️ `peekTraceparent` performs a **full protobuf decode** (`Tracker.swift:180`);
> the "without decoding its frames" in the doc comment refers to the semantic level.
>
> ⚠️ **Exactly the same coverage blind spot as android**: the call site is in `handleAnimationData` (`:326`),
> so it applies only to **streaming animation frames**. Transition frames do not go through here — a round consisting solely of transition frames yields no traceparent.

## 4. Providers — Agora is the only implementation

| `TransportStats` field | Agora | source |
|----------------------|-------|------|
| `packetsLost` / `packetsReceived` | ❌ **never populated** | — |
| `lossRatePct` | ✅ | `remoteVideoStats.packetLossRate` (`AgoraProvider.swift:445`) |
| `rttMs` | ✅ | `reportRtcStats.lastmileDelay × 2` (`:471`) |
| `jitterMs` | ✅ | `remoteAudioStats.jitterBufferDelay` (`:454`) |
| `freezeTimeSec` | ✅ collected | **never reported**, no corresponding metric |

The sentinel -1 means "not reported"; `getTransportStats` converts it to nil rather than 0 (comment at `:416-422`:
"would read as a flawless link").

The rationale for deriving `rttMs` from `lastmileDelay × 2` is the same as android's: Agora native offers no server
round-trip, and `gatewayRtt` measures the local router and is disabled on iOS 14+. The conversion assumes a symmetric path;
**the measurement recorded in the iOS comment is ~22ms one-way** (the android comment records 3-7ms — the two platforms measured different numbers,
and each uses the value from its own comment).

`jitterMs` is the **audio jitter buffer depth**, not video RTP jitter (`:431-433`) —
same as android, so a cross-platform dashboard must not stack it directly against web's LiveKit `inbound-rtp.jitter`.

## 5. Known Defects and TODOs

### Shared with android (9 items)

1. Buckets for the 4 `rtc_transport_*` metrics have landed in the host SDK (`c886419`) but are unreleased → production still uses default buckets
2. `rtc_playback_stats` does not carry `conversation_id` → the path from an event to its trace is broken
3. `rtc_jitter_buffer_overflow` has not followed web's removal
4. `rtc_jitter_buffer_starved` deduplication semantics differ from web (edge-triggered)
5. Inconsistent field naming on failed events (`reason` vs `description`)
6. `EndReason.disconnect` is a dead value
7. Trace wall clock is not ClockSync-calibrated, while the log channel is
8. Four semantic divergences between `rtc_session_summary` and web (§2.3)
9. `rtc_stream_stalled` is missing `conversation_id`

### iOS-only (2 items)

10. **`TelemetryIdentity.sdkVersion` is the only hand-written version constant across the three platforms** (§0) — SPM has no build-time
    injection. It has drifted twice, and **the existing v1.0.0 data carries the wrong version number with no way to correct it retroactively**; HEAD is fixed,
    and `scripts/check_version_consistency.sh` prevents a recurrence
11. **`emitPlaybackTrace` has no exception protection** — android wraps it in a try/catch, iOS runs unguarded

### Where iOS is better than the other two platforms (3 items)

- Native types are **preserved across the whole log / metric channel** (the android form of defect #5 does not apply)
- `AvatarSDK.inject` has a **Resource rebuild fallback**, so a late claim still takes effect
- `telemetry_kind` is a **real field**, not an empty promise in a comment

## Related

- Docs index → [`../README.md`](../README.md)
- Docs map → [`docs-map.md`](docs-map.md)
- Architecture → [`overview.md`](overview.md)
- Host SDK telemetry → `ios-sdk/docs/architecture/telemetry-fields.md`
- Cross-platform comparison → `avatarkit-android-rtc/docs/architecture/telemetry-fields.md`
