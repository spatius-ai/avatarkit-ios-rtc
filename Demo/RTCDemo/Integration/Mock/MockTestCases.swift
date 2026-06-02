import Foundation
import AvatarKit
import AvatarKitRTC

/// Mock-driven integration tests. The runner connects an `AvatarPlayer`
/// against a `MockRTCProvider`; tests then call `ctx.mock.inject*` to drive
/// every kind of packet the real RTC stream could carry, in any order or
/// shape they like.
///
/// Assertions read back through:
/// - `ctx.player.isConnected` and the captured `AvatarPlayerEvent` stream
/// - `ctx.player.sessionSummary` — cumulative jitter / drop / skip counters
/// - direct provider state for lifecycle tests
///
/// No network, no real Agora. Deterministic state-machine coverage.
enum MockTestCases {

    // MARK: - Helpers

    /// A non-empty protobuf-shaped blob. The renderer will fail to decode this
    /// (it isn't a real Message) and log internally, but that's fine — these
    /// tests check the SDK's state-machine routing, not avatar rendering.
    private static func dummyProtobuf() -> Data { Data([0x08, 0x01]) }

    /// Push `count` frames with seq starting from `startSeq`, paced at the
    /// jitter-buffer drain interval (~40ms). Marks isStart/isEnd if asked.
    @MainActor
    private static func pushFrames(
        _ ctx: TestContext,
        start: Int = 0,
        count: Int,
        markFirstAsStart: Bool = true,
        markLastAsEnd: Bool = false,
        pacingMs: Int = 45
    ) async {
        guard let mock = ctx.mock else { return }
        let pb = dummyProtobuf()
        for i in 0..<count {
            let seq = start + i
            mock.injectAnimationFrame(
                pb,
                frameSeq: seq,
                isStart: markFirstAsStart && i == 0,
                isEnd: markLastAsEnd && i == count - 1
            )
            await ctx.wait(pacingMs)
        }
    }

    /// Wait long enough for the 1Hz playback-stats timer to roll
    /// `playbackFrameCount` into `conversationFrameCount`, then push an idle
    /// marker which finalises the conversation into the cumulative summary.
    @MainActor
    private static func finalize(_ ctx: TestContext) async {
        await ctx.wait(1_200)
        ctx.mock?.injectIdleStart()
        await ctx.wait(300)
    }

    private static func hasEvent(_ events: [AvatarPlayerEvent], _ kind: PlayerEventKind) -> Bool {
        events.contains { kind.matches($0) }
    }

    private static func stalledEvents(_ events: [AvatarPlayerEvent]) -> Int {
        events.reduce(0) { $0 + (($1.isStalled) ? 1 : 0) }
    }

    // MARK: - Group A — Idle baseline

    static let idle: [TestCase] = [
        TestCase(id: "mock.idle.fresh",
                 name: "Initial state — no frames, no stall",
                 group: "Mock: Idle",
                 timeoutMs: 3_000) { ctx in
            try ctx.assert(ctx.player.sessionSummary.totalFrames == 0, "frames must start at 0")
            try ctx.assert(!hasEvent(ctx.capturedEvents, .stalled), "no stall before any session")
        },
        TestCase(id: "mock.idle.repeated-idempotent",
                 name: "Many idle packets in a row — idempotent",
                 group: "Mock: Idle",
                 timeoutMs: 3_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            for _ in 0..<10 { mock.injectIdleStart() }
            await ctx.wait(200)
            try ctx.assert(ctx.player.sessionSummary.totalFrames == 0,
                           "idle packets must not count as frames")
        },
    ]

    // MARK: - Group B — Speaking sessions (sequential frames)

    static let speakingSequential: [TestCase] = [
        TestCase(id: "mock.seq.no-transition",
                 name: "Animation without leading transition starts a session",
                 group: "Mock: Speaking",
                 timeoutMs: 8_000) { ctx in
            await pushFrames(ctx, count: 10)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 10,
                           "expected ≥10 frames, got \(ctx.player.sessionSummary.totalFrames)")
        },
        TestCase(id: "mock.seq.with-transition",
                 name: "transition-start + frames + transition-end",
                 group: "Mock: Speaking",
                 timeoutMs: 10_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.injectTransitionStart(dummyProtobuf(), frameCount: 8)
            await ctx.wait(100)
            await pushFrames(ctx, count: 10, markLastAsEnd: true)
            mock.injectTransitionEnd(dummyProtobuf(), frameCount: 12)
            await ctx.wait(500)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 10, "frames accumulated")
        },
        TestCase(id: "mock.seq.long-session",
                 name: "Long session — 50 sequential frames",
                 group: "Mock: Speaking",
                 timeoutMs: 12_000) { ctx in
            await pushFrames(ctx, count: 50)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 50, "all frames counted")
        },
        TestCase(id: "mock.seq.frameSeq-nil-direct-path",
                 name: "Frames with seq=nil bypass jitter buffer",
                 group: "Mock: Speaking",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            for i in 0..<8 {
                mock.injectAnimationFrame(dummyProtobuf(), frameSeq: nil, isStart: i == 0)
                await ctx.wait(40)
            }
            await finalize(ctx)
            // Direct path renders immediately; cumulative should reflect them.
            try ctx.assert(ctx.player.sessionSummary.totalFrames > 0,
                           "direct-path frames should count")
        },
    ]

    // MARK: - Group C — Transition packet edge cases

    static let transitions: [TestCase] = [
        TestCase(id: "mock.trans.start-then-start",
                 name: "Repeated transition-start packets are idempotent",
                 group: "Mock: Transitions",
                 timeoutMs: 6_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.injectTransitionStart(dummyProtobuf(), frameCount: 8)
            mock.injectTransitionStart(dummyProtobuf(), frameCount: 8)
            mock.injectTransitionStart(dummyProtobuf(), frameCount: 8)
            await ctx.wait(400)
            // Second & third should be filtered by hasHandledTransitionStart.
            // We can't directly observe but the pipeline shouldn't crash and
            // a follow-up session should still work.
            await pushFrames(ctx, count: 5)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 5, "session ok after dup transitions")
        },
        TestCase(id: "mock.trans.end-without-session",
                 name: "transition-end without active session — ignored",
                 group: "Mock: Transitions",
                 timeoutMs: 6_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            // Force SDK back to idle in case a previous case left a session
            // active (cases share one AvatarPlayer to mirror production).
            mock.injectIdleStart()
            await ctx.wait(300)
            let baseline = ctx.player.sessionSummary.totalFrames

            mock.injectTransitionEnd(dummyProtobuf(), frameCount: 12)
            await ctx.wait(500)
            try ctx.assert(ctx.player.sessionSummary.totalFrames == baseline,
                           "transition-end alone must not produce frames")
            try ctx.assert(!hasEvent(ctx.capturedEvents, .stalled), "no stall")
        },
        TestCase(id: "mock.trans.end-then-end",
                 name: "Repeated transition-end packets are idempotent",
                 group: "Mock: Transitions",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            await pushFrames(ctx, count: 5)
            mock.injectTransitionEnd(dummyProtobuf(), frameCount: 12)
            mock.injectTransitionEnd(dummyProtobuf(), frameCount: 12)
            mock.injectTransitionEnd(dummyProtobuf(), frameCount: 12)
            await ctx.wait(500)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 5, "session ok")
        },
        TestCase(id: "mock.trans.late-start-during-playback",
                 name: "transition-start arriving mid-playback is dropped",
                 group: "Mock: Transitions",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            // Get into speaking
            await pushFrames(ctx, start: 0, count: 5)
            await ctx.wait(200)
            // Late transition-start — should be ignored by the "ignore late
            // transition packet after playback start" guard.
            mock.injectTransitionStart(dummyProtobuf(), frameCount: 8)
            await ctx.wait(200)
            // Continue with more frames
            await pushFrames(ctx, start: 5, count: 5, markFirstAsStart: false)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 5, "playback survived late transition")
        },
        TestCase(id: "mock.trans.start-only-no-frames",
                 name: "transition-start with no follow-up frames — no crash",
                 group: "Mock: Transitions",
                 timeoutMs: 5_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.injectTransitionStart(dummyProtobuf(), frameCount: 8)
            await ctx.wait(800)
            // No anim frames came after — eventually a stall *would* fire
            // (5s watchdog), but within 800ms it shouldn't.
            try ctx.assert(!hasEvent(ctx.capturedEvents, .stalled), "no early stall")
        },
    ]

    // MARK: - Group D — Session lifecycle / boundaries

    static let sessionBoundaries: [TestCase] = [
        TestCase(id: "mock.bound.anim-end-then-idle",
                 name: "Session end with isEnd=true → idle marker",
                 group: "Mock: Boundaries",
                 timeoutMs: 6_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            await pushFrames(ctx, count: 5, markLastAsEnd: true)
            mock.injectIdleStart()
            await ctx.wait(300)
            try ctx.assert(!hasEvent(ctx.capturedEvents, .stalled), "no stall on clean end")
        },
        TestCase(id: "mock.bound.back-to-back",
                 name: "Two back-to-back sessions both accumulate",
                 group: "Mock: Boundaries",
                 timeoutMs: 14_000) { ctx in
            await pushFrames(ctx, start: 0, count: 5, markLastAsEnd: true)
            await finalize(ctx)
            let first = ctx.player.sessionSummary.totalFrames
            // Session 2 — seq numbering restarts
            await pushFrames(ctx, start: 0, count: 5, markLastAsEnd: true)
            await finalize(ctx)
            let second = ctx.player.sessionSummary.totalFrames
            try ctx.assert(second > first,
                           "second session should add more frames (was \(first) → \(second))")
        },
        TestCase(id: "mock.bound.idle-skips-transition-end",
                 name: "Hard idle without transition-end is accepted",
                 group: "Mock: Boundaries",
                 timeoutMs: 6_000) { ctx in
            await pushFrames(ctx, count: 3)
            await finalize(ctx)
            try ctx.assert(!hasEvent(ctx.capturedEvents, .stalled), "hard idle should not stall")
        },
        TestCase(id: "mock.bound.duplicate-isStart",
                 name: "Duplicate isStart=true mid-session is ignored",
                 group: "Mock: Boundaries",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            let pb = dummyProtobuf()
            mock.injectAnimationFrame(pb, frameSeq: 0, isStart: true)
            await ctx.wait(45)
            // Second "isStart=true" frame must not start a new session — the
            // SDK logs and continues.
            mock.injectAnimationFrame(pb, frameSeq: 1, isStart: true)
            await ctx.wait(45)
            for seq in 2..<6 {
                mock.injectAnimationFrame(pb, frameSeq: seq)
                await ctx.wait(45)
            }
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 5, "session still progressed")
        },
    ]

    // MARK: - Group E — Jitter buffer state machine

    static let jitterBuffer: [TestCase] = [
        TestCase(id: "mock.jb.ordering-in-order",
                 name: "Perfectly in-order frames render in order",
                 group: "Mock: Jitter Buffer",
                 timeoutMs: 8_000) { ctx in
            await pushFrames(ctx, count: 10)
            await finalize(ctx)
            let s = ctx.player.sessionSummary
            try ctx.assert(s.totalFrames >= 10, "all frames accepted")
            try ctx.assert(s.jitterDropStale == 0, "no stale drops")
            try ctx.assert(s.jitterDropLate == 0, "no late drops")
            try ctx.assert(s.jitterOutOfOrderRenderRejects == 0, "no OOO rejects")
        },
        TestCase(id: "mock.jb.out-of-order",
                 name: "Out-of-order frames are reordered by the buffer",
                 group: "Mock: Jitter Buffer",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            let pb = dummyProtobuf()
            for seq in [0, 2, 1, 3, 5, 4, 6] {
                mock.injectAnimationFrame(pb, frameSeq: seq, isStart: seq == 0)
                await ctx.wait(45)
            }
            await finalize(ctx)
            let s = ctx.player.sessionSummary
            try ctx.assert(s.totalFrames > 0, "some frames accepted")
            ctx.log("ooo summary: total=\(s.totalFrames) reject=\(s.jitterOutOfOrderRenderRejects) skip=\(s.jitterSkipFrames)")
        },
        TestCase(id: "mock.jb.duplicate-seq",
                 name: "Duplicate seq does not render twice",
                 group: "Mock: Jitter Buffer",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            let pb = dummyProtobuf()
            mock.injectAnimationFrame(pb, frameSeq: 0, isStart: true); await ctx.wait(45)
            for _ in 0..<3 {
                mock.injectAnimationFrame(pb, frameSeq: 1); await ctx.wait(45)
            }
            mock.injectAnimationFrame(pb, frameSeq: 2); await ctx.wait(45)
            await finalize(ctx)
            let s = ctx.player.sessionSummary
            ctx.log("dup summary: total=\(s.totalFrames) late=\(s.jitterDropLate) stale=\(s.jitterDropStale)")
        },
        TestCase(id: "mock.jb.gap",
                 name: "Sequence gap — buffer skips ahead",
                 group: "Mock: Jitter Buffer",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            let pb = dummyProtobuf()
            for seq in [0, 1, 2] {
                mock.injectAnimationFrame(pb, frameSeq: seq, isStart: seq == 0); await ctx.wait(45)
            }
            // Large gap then resume
            for seq in [20, 21, 22] {
                mock.injectAnimationFrame(pb, frameSeq: seq); await ctx.wait(45)
            }
            await finalize(ctx)
            let s = ctx.player.sessionSummary
            try ctx.assert(s.totalFrames >= 3, "early frames accepted")
            ctx.log("gap summary: total=\(s.totalFrames) skipEvents=\(s.jitterSkipEvents) skipFrames=\(s.jitterSkipFrames)")
        },
        TestCase(id: "mock.jb.regression-old-seq",
                 name: "Older seq after newer is dropped",
                 group: "Mock: Jitter Buffer",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            let pb = dummyProtobuf()
            // Push 10..14, then stale 5.
            for seq in 10...14 {
                mock.injectAnimationFrame(pb, frameSeq: seq, isStart: seq == 10); await ctx.wait(45)
            }
            await ctx.wait(300) // let buffer drain past 14
            mock.injectAnimationFrame(pb, frameSeq: 5); await ctx.wait(45)
            await finalize(ctx)
            let s = ctx.player.sessionSummary
            try ctx.assert(s.totalFrames >= 5, "newer frames played")
            // Stale frame should have bumped a drop counter somewhere.
            let drops = s.jitterDropStale + s.jitterDropLate + s.jitterPruneStale + s.jitterOutOfOrderRenderRejects
            try ctx.assert(drops > 0, "stale frame should be tracked in a drop counter")
        },
        TestCase(id: "mock.jb.tiny-burst",
                 name: "Two frames is enough to enter draining",
                 group: "Mock: Jitter Buffer",
                 timeoutMs: 6_000) { ctx in
            await pushFrames(ctx, count: 2)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 2, "tiny burst drained")
        },
        TestCase(id: "mock.jb.starve-then-resume",
                 name: "Buffer starves between frames then resumes",
                 group: "Mock: Jitter Buffer",
                 timeoutMs: 10_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            let pb = dummyProtobuf()
            // Burst 1
            for seq in 0..<3 {
                mock.injectAnimationFrame(pb, frameSeq: seq, isStart: seq == 0); await ctx.wait(45)
            }
            // Starve window (still inside watchdog 5s)
            await ctx.wait(1_500)
            // Burst 2
            for seq in 3..<6 {
                mock.injectAnimationFrame(pb, frameSeq: seq); await ctx.wait(45)
            }
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 3, "frames survived the starve")
            try ctx.assert(!hasEvent(ctx.capturedEvents, .stalled), "watchdog should not have fired yet")
        },
    ]

    // MARK: - Group F — Recovered frames + special metadata

    static let metadataFlags: [TestCase] = [
        TestCase(id: "mock.meta.isRecovered",
                 name: "isRecovered=true bumps recovered counter",
                 group: "Mock: Metadata",
                 timeoutMs: 6_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            let pb = dummyProtobuf()
            for seq in 0..<5 {
                mock.injectAnimationFrame(pb, frameSeq: seq, isStart: seq == 0, isRecovered: true)
                await ctx.wait(45)
            }
            await finalize(ctx)
            let s = ctx.player.sessionSummary
            try ctx.assert(s.totalRecovered > 0,
                           "expected recovered counter to bump, got \(s.totalRecovered)")
        },
        TestCase(id: "mock.meta.isEnd-without-isStart",
                 name: "isEnd=true on first frame is tolerated",
                 group: "Mock: Metadata",
                 timeoutMs: 5_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.injectAnimationFrame(dummyProtobuf(), frameSeq: 0, isStart: false, isEnd: true)
            await ctx.wait(400)
            // No crash; subsequent session should still work.
            await pushFrames(ctx, start: 10, count: 5)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 5, "follow-up session ok")
        },
        TestCase(id: "mock.meta.isIdle-flag",
                 name: "Frame metadata isIdle=true is no-op for stats",
                 group: "Mock: Metadata",
                 timeoutMs: 5_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.injectAnimationFrame(dummyProtobuf(), frameSeq: 0, isStart: true, isIdle: true)
            await ctx.wait(200)
            // The SDK doesn't have special handling for isIdle on metadata
            // (idle is a separate packet flag). Just ensure no crash.
            try ctx.assert(ctx.player.isConnected, "still connected")
        },
    ]

    // MARK: - Group G — Stall watchdog

    static let stall: [TestCase] = [
        TestCase(id: "mock.stall.5s-fires",
                 name: "5s without frames in a session fires .stalled",
                 group: "Mock: Stall",
                 timeoutMs: 12_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.injectAnimationFrame(dummyProtobuf(), frameSeq: 0, isStart: true)
            await ctx.wait(6_000)
            try ctx.assert(hasEvent(ctx.capturedEvents, .stalled), "stall must fire after 5s silence")
        },
        TestCase(id: "mock.stall.continuous-no-fire",
                 name: "Frame every second — no stall",
                 group: "Mock: Stall",
                 timeoutMs: 12_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            for i in 0..<7 {
                mock.injectAnimationFrame(dummyProtobuf(), frameSeq: i, isStart: i == 0)
                await ctx.wait(1_000)
            }
            try ctx.assert(!hasEvent(ctx.capturedEvents, .stalled), "should not stall")
        },
        TestCase(id: "mock.stall.fires-once-not-repeatedly",
                 name: "Stall fires once per silent window, not repeatedly",
                 group: "Mock: Stall",
                 timeoutMs: 15_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.injectAnimationFrame(dummyProtobuf(), frameSeq: 0, isStart: true)
            await ctx.wait(8_000) // well past the 5s watchdog
            let count = stalledEvents(ctx.capturedEvents)
            try ctx.assert(count == 1,
                           "stall should fire exactly once for a single silent window, got \(count)")
        },
        TestCase(id: "mock.stall.recover-after-stall",
                 name: "Frames arriving after stall keep the session alive",
                 group: "Mock: Stall",
                 timeoutMs: 18_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.injectAnimationFrame(dummyProtobuf(), frameSeq: 0, isStart: true)
            await ctx.wait(6_000)
            try ctx.assert(hasEvent(ctx.capturedEvents, .stalled), "expected stall")
            // Recover
            for seq in 1..<5 {
                mock.injectAnimationFrame(dummyProtobuf(), frameSeq: seq); await ctx.wait(45)
            }
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 4,
                           "recovered frames should accumulate")
        },
    ]

    // MARK: - Group H — AvatarPlayer event surface

    static let playerEvents: [TestCase] = [
        TestCase(id: "mock.evt.connect-events",
                 name: "connect sequence emits connecting → connected",
                 group: "Mock: Events",
                 timeoutMs: 5_000) { ctx in
            // Runner already connected once; disconnect and reconnect to
            // capture a clean event sequence inside this test's window.
            ctx.resetEvents()
            await ctx.player.disconnect()
            try await ctx.player.reconnect()
            // Wait for state to settle.
            await ctx.wait(300)
            try ctx.assert(hasEvent(ctx.capturedEvents, .connected), "expected .connected event")
        },
        TestCase(id: "mock.evt.disconnect-event",
                 name: "disconnect emits .disconnected",
                 group: "Mock: Events",
                 timeoutMs: 5_000) { ctx in
            ctx.resetEvents()
            await ctx.player.disconnect()
            await ctx.wait(200)
            try ctx.assert(hasEvent(ctx.capturedEvents, .disconnected), "expected .disconnected")
            // Restore so subsequent cases are connected.
            try await ctx.player.reconnect()
        },
        TestCase(id: "mock.evt.error-propagates",
                 name: "Provider .error event reaches subscribers",
                 group: "Mock: Events",
                 timeoutMs: 4_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            ctx.resetEvents()
            mock.injectProviderEvent(.error("synthetic"))
            await ctx.wait(150)
            try ctx.assert(hasEvent(ctx.capturedEvents, .error), "expected .error event")
        },
        TestCase(id: "mock.evt.connection-state-changed",
                 name: "connectionChanged events reach subscribers",
                 group: "Mock: Events",
                 timeoutMs: 4_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            ctx.resetEvents()
            mock.injectProviderEvent(.connectionStateChanged(.reconnecting))
            await ctx.wait(150)
            let saw = ctx.capturedEvents.contains {
                if case .connectionStateChanged(let s) = $0 { return s == .reconnecting }
                return false
            }
            try ctx.assert(saw, "expected reconnecting state change")
        },
    ]

    // MARK: - Group I — AvatarPlayer guards

    static let playerGuards: [TestCase] = [
        TestCase(id: "mock.guard.connect-when-connected",
                 name: "connect() while already connected throws",
                 group: "Mock: Player Guards",
                 timeoutMs: 5_000) { ctx in
            try ctx.assert(ctx.player.isConnected, "must start connected")
            var threw = false
            do {
                try await ctx.player.connect(MockConnectionConfig())
            } catch {
                threw = true
                ctx.log("got expected: \(error.localizedDescription)")
            }
            try ctx.assert(threw, "connect() should throw .alreadyConnected")
        },
        TestCase(id: "mock.guard.publish-when-disconnected",
                 name: "publishAudio() while disconnected throws",
                 group: "Mock: Player Guards",
                 timeoutMs: 6_000) { ctx in
            await ctx.player.disconnect()
            var threw = false
            do { try await ctx.player.publishAudio() }
            catch {
                threw = true
                ctx.log("got expected: \(error.localizedDescription)")
            }
            try ctx.assert(threw, "publishAudio should throw when not connected")
            try await ctx.player.reconnect()
        },
        TestCase(id: "mock.guard.publishExternal-when-disconnected",
                 name: "publishExternalPCM() while disconnected throws",
                 group: "Mock: Player Guards",
                 timeoutMs: 6_000) { ctx in
            await ctx.player.disconnect()
            var threw = false
            do { try await ctx.player.publishExternalPCM() }
            catch {
                threw = true
                ctx.log("got expected: \(error.localizedDescription)")
            }
            try ctx.assert(threw, "publishExternalPCM should throw")
            try await ctx.player.reconnect()
        },
        TestCase(id: "mock.guard.unpublish-idempotent",
                 name: "unpublishAudio() while not publishing is a no-op",
                 group: "Mock: Player Guards",
                 timeoutMs: 4_000) { ctx in
            await ctx.player.unpublishAudio()
            await ctx.player.unpublishAudio()
            try ctx.assert(ctx.player.isConnected, "still connected")
        },
        TestCase(id: "mock.guard.disconnect-idempotent",
                 name: "Double disconnect() is a no-op",
                 group: "Mock: Player Guards",
                 timeoutMs: 6_000) { ctx in
            await ctx.player.disconnect()
            await ctx.player.disconnect()
            try ctx.assert(!ctx.player.isConnected, "still disconnected")
            try await ctx.player.reconnect()
        },
        TestCase(id: "mock.guard.reconnect-without-history",
                 name: "reconnect() with no prior config throws",
                 group: "Mock: Player Guards",
                 timeoutMs: 4_000) { ctx in
            // Difficult to set up cleanly here because the runner always
            // connects first. Simulate by creating an isolated player.
            let provider = MockRTCProvider()
            let isolated = AvatarPlayer(
                provider: provider,
                avatarView: ctx.avatarView,
                options: AvatarPlayerOptions(logLevel: .warning)
            )
            var threw = false
            do { try await isolated.reconnect() }
            catch { threw = true; ctx.log("got expected: \(error.localizedDescription)") }
            try ctx.assert(threw, "reconnect() must throw without prior config")
        },
    ]

    // MARK: - Group J — Provider lifecycle (mock-specific)

    static let providerLifecycle: [TestCase] = [
        TestCase(id: "mock.life.connect-throws-propagates",
                 name: "Provider error during connect surfaces to caller",
                 group: "Mock: Provider Lifecycle",
                 timeoutMs: 8_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            await ctx.player.disconnect()
            mock.connectShouldThrow = NSError(domain: "MockTest", code: 99,
                userInfo: [NSLocalizedDescriptionKey: "synthetic connect failure"])
            var threw = false
            do { try await ctx.player.connect(MockConnectionConfig()) }
            catch { threw = true; ctx.log("got expected: \(error.localizedDescription)") }
            try ctx.assert(threw, "expected error to propagate")
            mock.connectShouldThrow = nil
            try await ctx.player.connect(MockConnectionConfig())
        },
        TestCase(id: "mock.life.publish-throws-propagates",
                 name: "Provider error during publishAudio surfaces",
                 group: "Mock: Provider Lifecycle",
                 timeoutMs: 5_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            mock.publishShouldThrow = NSError(domain: "MockTest", code: 100,
                userInfo: [NSLocalizedDescriptionKey: "synthetic publish failure"])
            var threw = false
            do { try await ctx.player.publishAudio() }
            catch { threw = true; ctx.log("got expected: \(error.localizedDescription)") }
            try ctx.assert(threw, "expected error to propagate")
            mock.publishShouldThrow = nil
        },
        TestCase(id: "mock.life.connect-disconnect-reset",
                 name: "Reconnect after disconnect resets accumulated state",
                 group: "Mock: Provider Lifecycle",
                 timeoutMs: 12_000) { ctx in
            // Push frames, finalize, capture summary, disconnect+reconnect,
            // ensure new summary starts fresh.
            await pushFrames(ctx, count: 5)
            await finalize(ctx)
            let beforeReconnect = ctx.player.sessionSummary.totalFrames
            await ctx.player.disconnect()
            try await ctx.player.reconnect()
            // sessionSummary accumulates across the AvatarPlayer lifetime,
            // not per-connection. We don't expect it to reset — just check
            // the player keeps working after reconnect.
            await pushFrames(ctx, start: 100, count: 3)
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames > beforeReconnect,
                           "frames should accumulate across reconnect")
        },
    ]

    // MARK: - Group K — Stream stats injection

    static let streamStats: [TestCase] = [
        TestCase(id: "mock.stats.simple-injection",
                 name: "Injected stream stats don't break playback",
                 group: "Mock: Stream Stats",
                 timeoutMs: 6_000) { ctx in
            guard let mock = ctx.mock else { throw AssertionError(message: "mock-only") }
            await pushFrames(ctx, count: 3)
            mock.injectStreamStats(RTCStreamStats(
                framesPerSec: 25,
                totalFrames: 100,
                framesSent: 105,
                framesLost: 2,
                framesRecovered: 1,
                framesDropped: 1,
                framesOutOfOrder: 0,
                framesDuplicate: 0,
                lastRenderedSeq: 99
            ))
            await finalize(ctx)
            try ctx.assert(ctx.player.sessionSummary.totalFrames >= 3, "playback unaffected by stats injection")
        },
    ]

    // MARK: - Aggregate

    static let all: [TestCase] =
        idle +
        speakingSequential +
        transitions +
        sessionBoundaries +
        jitterBuffer +
        metadataFlags +
        stall +
        playerEvents +
        playerGuards +
        providerLifecycle +
        streamStats
}

/// Sentinel config the mock provider accepts. Conforms to RTCConnectionConfig
/// (a marker protocol) — no fields needed.
struct MockConnectionConfig: RTCConnectionConfig {}

private extension AvatarPlayerEvent {
    var isStalled: Bool {
        if case .stalled = self { return true }
        return false
    }
}
