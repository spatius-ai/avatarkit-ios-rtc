import Foundation
import AvatarKit

/// Renderer abstraction injected by AvatarPlayer. Adapts AvatarView's
/// single-frame APIs to the surface AnimationHandler needs. Kept as a
/// protocol so AnimationHandler stays platform-agnostic (mirrors web's
/// `AvatarRenderer` interface).
/// Every method is synchronous, and that is load-bearing rather than
/// incidental. Playback is paced by a scheduler that decides which frame
/// belongs in each 40ms slot; an `async` render would only mean "the frame was
/// handed off during this slot", not "the frame reached the screen in it", and
/// two frames' continuations can resume out of order — a late one overwriting
/// a newer frame. Rendering inside the slot keeps order and timing where the
/// scheduler can see them. Mirrors web's synchronous `AvatarRenderer`.
@MainActor protocol AvatarRendererAdapter: AnyObject {
    func renderFromProtobuf(_ data: Data)
    func renderFrame(_ frame: Frame?, startIdle: Bool)
    func generateTransitionToFrame(_ data: Data, frameCount: Int) -> [Frame]
    func generateTransitionToIdle(frameCount: Int) -> [Frame]
    func isReady() -> Bool
}

/// Configuration for AnimationHandler. Matches web's AnimationHandlerConfig.
struct AnimationHandlerConfig {
    var transitionStartFrameCount: Int = 8
    var transitionEndFrameCount: Int = 20
    var enableJitterBuffer: Bool = true
    /// Max delay (ms) a frame can sit in the jitter buffer before being rendered.
    /// Also controls how long to wait for a missing frame before skipping ahead.
    var maxBufferDelayMs: Int = 80
    var providerName: String = ""
    var onStreamStalled: (@MainActor () -> Void)?
}

/// Jitter buffer state machine.
private enum BufferState {
    case direct
    case filling
    case draining
    case starved
}

/// A frame held in the jitter buffer awaiting playback.
private struct BufferedFrame {
    let protobufData: Data
    let seq: Int
    let receivedAt: TimeInterval
    let isRecovered: Bool
}

/// One run of consecutive slots that rendered nothing — the picture frozen on
/// whatever was last drawn.
private struct StallRun {
    /// Sequence the drain loop was waiting on.
    var waitingForSeq: Int
    /// Monotonic start of the freeze.
    var startedAt: TimeInterval
    /// Slots spent frozen. The duration comes from the clock rather than this
    /// count, since the clock stops while the buffer is starved.
    var ticks: Int
    /// True when the freeze began because the buffer was empty.
    var startedStarved: Bool
    /// Monotonic end, once a frame finally renders.
    var endedAt: TimeInterval = 0
}

private struct SkippedRange {
    let from: Int
    let to: Int
    let at: TimeInterval
}

/// How a round ended.
private enum EndReason: String {
    case none = ""
    case transition
    case idlePacket = "idle_packet"
    case stallTimeout = "stall_timeout"
    case disconnect
}

/// Playback quality for one round: what reached the screen, as opposed to the
/// jitter counters which describe what reached the buffer.
private struct QualityStats {
    /// Frames the start transition was asked to produce.
    var startTransitionExpected = 0
    /// Frames of the start transition actually rendered.
    var startTransitionRendered = 0
    /// Frames the end transition was asked to produce.
    var endTransitionExpected = 0
    /// Frames of the end transition actually rendered.
    var endTransitionRendered = 0
    /// Wall-clock boundaries of the two transitions, so the trace can lay the
    /// round out as one continuous timeline instead of a few isolated markers.
    /// Zero while the corresponding transition has not run.
    var startTransitionBeganAt: TimeInterval = 0
    var startTransitionEndedAt: TimeInterval = 0
    var endTransitionBeganAt: TimeInterval = 0
    /// Completed stall runs.
    var stalls: [StallRun] = []
    /// Stall run in progress, if the drain loop is currently spinning.
    var openStall: StallRun?
    /// Sequence ranges that were skipped without ever rendering.
    var skipped: [SkippedRange] = []
    /// How the round ended.
    var endReason: EndReason = .none
    /// Whether the frame carried by the transition-end packet is the one last
    /// rendered. False means the round's final frames never reached the screen.
    /// Nil when no transition-end packet arrived.
    var tailIntact: Bool?
    /// Frames still queued when the round ended; these are discarded unrendered.
    var tailDiscarded = 0
}

private struct JitterStatsCounters {
    var jitterDropStale = 0
    var jitterDropLate = 0
    var jitterDropOverflow = 0
    var jitterPruneStale = 0
    var jitterSkipEvents = 0
    var jitterSkipFrames = 0
    var jitterStarved = 0
    var jitterNoInOrder = 0
    var jitterOutOfOrderRenderRejects = 0
}

/// Cumulative playback statistics. Exposed via `AvatarPlayer.sessionSummary`
/// for tests and telemetry consumers; emitted as `rtc_session_summary` on
/// disconnect.
public struct AnimationSessionSummary: Sendable {
    public var totalFrames = 0
    public var totalLost = 0
    public var totalRecovered = 0
    public var totalDropped = 0
    public var avgFps = 0
    public var jitterDropStale = 0
    public var jitterDropLate = 0
    public var jitterDropOverflow = 0
    public var jitterPruneStale = 0
    public var jitterSkipEvents = 0
    public var jitterSkipFrames = 0
    public var jitterStarved = 0
    public var jitterNoInOrder = 0
    public var jitterOutOfOrderRenderRejects = 0

    public init() {}
}

/// Orchestrates animation playback and transitions for RTC streams.
///
/// 1:1 port of `@spatius/avatarkit-rtc`'s `AnimationHandler.ts`. Handles:
/// - Direct + jitter-buffer render paths at 25fps
/// - Out-of-order / duplicate / late frame detection and recovery
/// - Idle ↔ speaking transition state machine
/// - Stall watchdog (5s no-frame → fallback to idle + notify caller)
/// - Per-conversation and per-session playback stats
///
/// Used internally by AvatarPlayer.
@MainActor final class AnimationHandler {
    private let logger = RTCLogger("AnimationHandler")
    private let renderer: AvatarRendererAdapter
    private var config: AnimationHandlerConfig

    // Frame tracking
    private var animationFrameCount = 0
    private var lastRenderedFrameSeq: Int = -1
    private var renderedFrameCount = 0

    // Transition state
    private var isPlayingTransition = false
    private var isTransitioningToIdle = false
    private var transitionFrames: [Frame] = []
    private var transitionFrameIndex = 0

    /// Frame count of an end transition that has been booked but not yet
    /// started, or nil when none is pending.
    private var pendingEndTransitionFrames: Int?
    /// Payload of the booked end transition's packet, held so the tail check
    /// runs against the frame that actually ended up on screen.
    private var pendingEndTransitionTail: Data?
    /// Playback slots still owed to the queued frames before the end transition
    /// may take over — the jitter buffer's initial fill, repaid at the end of
    /// the round. Counted down one slot per tick.
    private var endTransitionSlotsOwed = 0

    // Guards against race conditions during async transition generation
    private var isGeneratingStartTransition = false
    private var isGeneratingEndTransition = false

    // Session-level flags — reset in resetTracking() for new sessions
    private var hasHandledTransitionStart = false
    private var hasHandledTransitionEnd = false

    // Watchdog
    private var lastFrameReceivedTime: TimeInterval = 0
    private var isInSession = false
    private var watchdogTask: Task<Void, Never>?
    private var hasReportedStall = false
    private static let stallTimeoutMs = 5000
    private var isStalledFallback = false

    // Playback stats
    private var playbackStatsTask: Task<Void, Never>?
    private var playbackFrameCount = 0
    private var playbackFrameTimestamps: [TimeInterval] = []
    private var playbackGapCount = 0
    private var playbackExpectedSeq: Int = -1

    // Jitter buffer
    private var bufferState: BufferState = .direct
    private var frameBuffer: [Int: BufferedFrame] = [:]
    private var bufferNextSeq: Int = -1
    private static let bufferMaxSize = 4
    private static let bufferInitialFill = 2

    /// The single playback clock. Transition frames and buffered stream frames
    /// share it: each tick asks "what belongs in this slot" and renders exactly
    /// one thing, so the two sources can never both drive the renderer.
    ///
    /// They used to run as two independent chains with no mutual exclusion,
    /// which left a short slot at every hand-over (28ms against a 40ms
    /// interval) and put two writers on the renderer for the duration of a
    /// transition.
    private var playbackTask: Task<Void, Never>?
    /// Target time of the slot most recently scheduled, on the monotonic clock.
    ///
    /// Slots are paced on a fixed grid rather than by waiting a flat interval
    /// after each render: a timer only guarantees *at least* its delay, so a
    /// flat wait lets every late callback push the whole sequence further out
    /// and the error compounds frame after frame. Anchoring each slot to
    /// `previous target + interval` absorbs a late callback into the next
    /// delay instead.
    private var playbackGridSlot: TimeInterval = 0
    private static let frameIntervalMs: TimeInterval = 40

    /// Whether the renderer is currently showing AvatarKit's idle loop. Guards
    /// the trailing idle packets that follow an end transition from redundantly
    /// resetting the idle loop.
    private var isIdle = true
    /// Payload of the frame last put on screen, for the tail check.
    private var lastRenderedPayload: Data?
    /// Monotonic time the previous frame reached the screen, for the gap probe.
    private var lastRenderLogAt: TimeInterval = 0
    /// Playback quality for the round in progress.
    private var conversationQuality = QualityStats()
    /// Frames skipped without ever rendering, this round.
    private var conversationSkipped = 0

    // Cumulative session stats
    private var cumulativeTotalFrames = 0
    private var cumulativeLost = 0
    private var cumulativeRecovered = 0
    private var cumulativeDropped = 0
    private var cumulativeFpsReadings: [Int] = []
    private var cumulativeJitterStats = JitterStatsCounters()

    // Per-conversation stats
    private var conversationFrameCount = 0
    private var conversationLost = 0
    private var conversationRecovered = 0
    private var conversationDropped = 0
    private var conversationFpsReadings: [Int] = []
    private var conversationStartTime: TimeInterval = 0
    private var conversationJitterStats = JitterStatsCounters()

    init(renderer: AvatarRendererAdapter, config: AnimationHandlerConfig = AnimationHandlerConfig()) {
        self.renderer = renderer
        self.config = config
    }

    // MARK: - Public hooks (called by AvatarPlayer)

    /// Handle a streaming animation frame.
    func handleAnimationData(_ protobufData: Data, frameSeq: Int?, isRecovered: Bool) {
        // A start transition is the run-up into this very stream: cutting it
        // short the instant the first frame lands is what kept it from ever
        // finishing — the frames arrive well before it has played out, so it
        // was routinely stopped a third of the way through and the picture
        // jumped into speech. Let it play; these frames buffer and the drain
        // loop picks them up when it ends, which is exactly the hand-over the
        // extra transition frame was sized for.
        //
        // An end transition is a different matter: it is winding down toward
        // idle, and a streamed frame means a new round has begun, so it must
        // give way.
        if isPlayingTransition && isTransitioningToIdle {
            stopTransition()
        }

        let now = nowMs()
        if hasReportedStall {
            let stallDuration = Int(now - lastFrameReceivedTime)
            logger.info("Data stream resumed after \(stallDuration)ms stall")
            hasReportedStall = false
        }
        if isStalledFallback {
            logger.info("Resuming from stall fallback, rendering directly without transition")
            isStalledFallback = false
        }
        lastFrameReceivedTime = now
        animationFrameCount += 1

        // Ensure session-level watchdog/stats are running even if transition packet was lost.
        ensureSessionActive(frameSeq: frameSeq)

        if config.enableJitterBuffer, let seq = frameSeq {
            bufferFrame(protobufData, seq: seq, isRecovered: isRecovered)
            return
        }

        // Direct path
        if let seq = frameSeq, lastRenderedFrameSeq != -1 {
            if seq < lastRenderedFrameSeq {
                logger.warn("OUT-OF-ORDER: seq=\(seq), lastRendered=\(lastRenderedFrameSeq)\(isRecovered ? " [RECOVERED]" : ""), discarding")
                conversationDropped += 1
                return
            } else if seq == lastRenderedFrameSeq {
                return
            } else if seq > lastRenderedFrameSeq + 1 {
                let gap = seq - lastRenderedFrameSeq - 1
                logger.warn("GAP: \(gap) frame(s) between \(lastRenderedFrameSeq) and \(seq)\(isRecovered ? " [RECOVERED]" : "")")
            }
        }
        if let seq = frameSeq {
            lastRenderedFrameSeq = seq
        }

        renderedFrameCount += 1
        if isRecovered { conversationRecovered += 1 }

        renderer.renderFromProtobuf(protobufData)
        logRenderedFrame(source: "direct", seq: frameSeq, isRecovered: isRecovered)

        playbackFrameTimestamps.append(nowMs())
        playbackFrameCount += 1
        if let seq = frameSeq {
            if playbackExpectedSeq >= 0 && seq > playbackExpectedSeq {
                playbackGapCount += seq - playbackExpectedSeq
            }
            playbackExpectedSeq = seq + 1
        }
    }

    /// Handle the idle-to-speaking transition packet.
    func handleTransitionData(_ protobufData: Data, frameCount: Int?) {
        logger.info("Start transition packet received bytes=\(protobufData.count), requestedFrames=\(frameCount ?? config.transitionStartFrameCount), hasHandledStart=\(hasHandledTransitionStart), isInSession=\(isInSession), isPlayingTransition=\(isPlayingTransition), isGeneratingStart=\(isGeneratingStartTransition), lastRenderedSeq=\(lastRenderedFrameSeq), bufferState=\(bufferStateName), buffered=\(frameBuffer.count)")

        // A start-transition packet that arrives while we're still playing the
        // previous conversation's end transition (speak→idle) is the next
        // conversation beginning. Don't drop it as "late": stop the end
        // transition and reset session tracking so this start transition plays
        // normally. generateTransitionToFrame anchors on the current rendered
        // frame, so it smoothly continues from wherever the end transition was.
        if isPlayingTransition && isTransitioningToIdle {
            stopTransition()
            resetTracking()
        }

        if hasHandledTransitionStart { return }
        if isPlayingTransition && !isTransitioningToIdle { return }
        if isGeneratingStartTransition { return }
        if !renderer.isReady() {
            logger.warn("Renderer not ready for transition")
            return
        }

        // Once streaming playback has started, start-transition packets are stale.
        if isInSession && (lastRenderedFrameSeq >= 0 || !frameBuffer.isEmpty || bufferState != .direct) {
            hasHandledTransitionStart = true
            logger.warn("Ignoring late transition packet after playback start (lastRenderedSeq=\(lastRenderedFrameSeq), bufferState=\(bufferStateName), buffered=\(frameBuffer.count))")
            return
        }

        hasHandledTransitionStart = true
        hasHandledTransitionEnd = false
        ensureSessionActive(frameSeq: nil)

        // One extra frame covers the jitter buffer's initial fill. Draining
        // starts as soon as bufferInitialFill frames are held, and the first of
        // those arrives while the transition is still running — so the wait is
        // for the second one, a single frame interval. That interval used to be
        // spent on a still picture between the transition ending and playback
        // starting; extending the transition across it fills the same stretch
        // with motion, and the round does not start any later.
        let frames = (frameCount ?? config.transitionStartFrameCount)
            + (Self.bufferInitialFill - 1)
        logger.info("Generating \(frames) transition frames to target")
        isGeneratingStartTransition = true

        conversationQuality.startTransitionExpected = frames
        // Generate one frame more than will be played, then drop the last one.
        //
        // The generator forces its final frame to the exact target it was
        // given, and that target is the frame the stream then opens with.
        // Playing the full sequence therefore puts that frame on screen twice —
        // once ending the transition, once opening playback — holding the
        // picture still for an extra interval right where speech begins.
        // Dropping it lands the transition one step short, so the stream's
        // first frame continues the motion instead of repeating it.
        let generated = renderer.generateTransitionToFrame(protobufData, frameCount: frames + 1)
        let transitionFrames = generated.isEmpty ? generated : Array(generated.dropLast())
        logger.info("Generated \(transitionFrames.count) transition frames")
        isPlayingTransition = true
        isTransitioningToIdle = false
        self.transitionFrames = transitionFrames
        transitionFrameIndex = 0
        isGeneratingStartTransition = false
        // The transition rides the same clock as the stream that follows it, so
        // the hand-over is just another slot rather than a seam between two
        // independently-paced chains.
        startPlaybackClock()
    }

    /// Handle the speaking-to-idle transition packet. `protobufData` is the
    /// SEI payload but its contents are no longer needed — the SDK computes
    /// the transition entirely from its internal `currentFrame` to the idle
    /// start. Kept in the signature for SEI parser compatibility.
    func handleTransitionToIdle(_ protobufData: Data, frameCount: Int?) {
        if !isInSession {
            logger.info("Ignoring transition end packet with no active session")
            return
        }
        if hasHandledTransitionEnd { return }
        if isPlayingTransition && isTransitioningToIdle { return }
        if isGeneratingEndTransition { return }
        if !renderer.isReady() {
            logger.warn("Renderer not ready for transition to idle")
            renderer.renderFrame(nil, startIdle: true)
            logRenderedFrame(source: "idle", seq: nil, isRecovered: false)
            return
        }

        hasHandledTransitionEnd = true
        conversationQuality.endReason = .transition

        // The jitter buffer's initial fill is a debt that has to be repaid here.
        //
        // Playback holds the first arriving frame back until bufferInitialFill
        // frames are queued, so every frame goes on screen that much later than
        // the server sent it — the driving service knows this and delays the
        // audio to match. What it does not do is delay this packet: it is sent
        // as soon as the last animation frame goes out, as if playback were
        // already finished. It is not; the frames covering that initial fill
        // are still queued, and their audio is still playing. Cutting to the
        // end transition here would take the picture into idle while the round
        // is still being spoken.
        //
        // So let the clock run out the debt first — the same count the opening
        // transition was extended by, for the same reason — and only then hand
        // over.
        let owed = Self.bufferInitialFill - 1
        pendingEndTransitionFrames = frameCount ?? config.transitionEndFrameCount
        pendingEndTransitionTail = protobufData
        endTransitionSlotsOwed = owed

        // Nothing is pacing playback (the buffer starved, or it never filled),
        // so no future slot is coming to run the debt down — hand over now.
        if owed <= 0 || playbackTask == nil {
            beginEndTransition()
        }
    }

    /// Start the end transition that `handleTransitionToIdle` booked, once the
    /// slots owed to the queued frames have been repaid.
    private func beginEndTransition() {
        guard let frames = pendingEndTransitionFrames, !isGeneratingEndTransition else {
            return
        }
        pendingEndTransitionFrames = nil
        endTransitionSlotsOwed = 0

        // The debt has been repaid, so whatever is on screen now is the round's
        // last spoken frame. Comparing the packet against it says whether the
        // tail made it — nothing else can, since loss is detected from a gap to
        // the *following* frame and the final frame has none.
        if let tail = pendingEndTransitionTail {
            conversationQuality.tailIntact = isSameFrameAsLastRendered(tail)
        }
        pendingEndTransitionTail = nil
        // Anything still queued past the repaid slots is genuinely dropped.
        conversationQuality.tailDiscarded = frameBuffer.count

        // Drop the leftovers so they cannot interleave with the transition.
        flushBuffer()

        conversationQuality.endTransitionExpected = frames
        logger.info("Generating \(frames) transition frames to idle")
        isGeneratingEndTransition = true

        let transitionFrames = renderer.generateTransitionToIdle(frameCount: frames)
        logger.info("Generated \(transitionFrames.count) transition frames")
        isPlayingTransition = true
        isTransitioningToIdle = true
        self.transitionFrames = transitionFrames
        transitionFrameIndex = 0
        isGeneratingEndTransition = false

        // Resume the grid the stream was on rather than re-anchoring to this
        // instant, so the transition's opening frame lands one full interval
        // after the last stream frame instead of right on its heels.
        startPlaybackClock(resumeGrid: true)
    }

    /// Switch to idle animation immediately. Reports conversation stats first.
    func startIdle() {
        // Every route to idle lands here. A transition-end packet has already
        // recorded its reason; anything still unset arrived another way — the
        // watchdog giving up, or a bare idle packet with no end transition,
        // which cuts straight to idle with no blend and is what a viewer sees
        // as a jump.
        if conversationQuality.endReason == .none {
            conversationQuality.endReason = isStalledFallback ? .stallTimeout : .idlePacket
            conversationQuality.tailDiscarded = frameBuffer.count
        }
        closeStallRun()
        reportConversationStats()
        isInSession = false
        hasReportedStall = false

        // Already idle — do not re-enter. Re-rendering idle resets AvatarKit's
        // idle frame index to 0, which snaps the pose mid-loop instead of
        // leaving the running idle animation untouched.
        if isIdle { return }
        isIdle = true
        stopPlaybackClock()
        renderer.renderFrame(nil, startIdle: true)
        logRenderedFrame(source: "idle", seq: nil, isRecovered: false)
    }

    /// Reset session-level frame tracking (called at session boundaries).
    func resetTracking() {
        lastRenderedFrameSeq = -1
        renderedFrameCount = 0
        animationFrameCount = 0
        hasHandledTransitionStart = false
        hasHandledTransitionEnd = false
        resetPlaybackStats()
        flushBuffer()
        logger.info("Frame tracking reset")
    }

    var isInTransition: Bool {
        isPlayingTransition || isGeneratingStartTransition || isGeneratingEndTransition
    }

    func stopTransition() {
        if isPlayingTransition || isGeneratingStartTransition || isGeneratingEndTransition {
            logger.info("Stopping transition playback")
        }
        isPlayingTransition = false
        isTransitioningToIdle = false
        isGeneratingStartTransition = false
        isGeneratingEndTransition = false
        transitionFrames = []
        transitionFrameIndex = 0
        pendingEndTransitionFrames = nil
        pendingEndTransitionTail = nil
        endTransitionSlotsOwed = 0
        flushBuffer()
    }

    /// Cumulative playback statistics — public so AvatarPlayer can surface
    /// them via `sessionSummary` to tests / app code.
    public func getSessionSummary() -> AnimationSessionSummary {
        var s = AnimationSessionSummary()
        s.totalFrames = cumulativeTotalFrames
        s.totalLost = cumulativeLost
        s.totalRecovered = cumulativeRecovered
        s.totalDropped = cumulativeDropped
        s.avgFps = cumulativeFpsReadings.isEmpty ? 0 :
            Int((Double(cumulativeFpsReadings.reduce(0, +)) / Double(cumulativeFpsReadings.count)).rounded())
        s.jitterDropStale = cumulativeJitterStats.jitterDropStale
        s.jitterDropLate = cumulativeJitterStats.jitterDropLate
        s.jitterDropOverflow = cumulativeJitterStats.jitterDropOverflow
        s.jitterPruneStale = cumulativeJitterStats.jitterPruneStale
        s.jitterSkipEvents = cumulativeJitterStats.jitterSkipEvents
        s.jitterSkipFrames = cumulativeJitterStats.jitterSkipFrames
        s.jitterStarved = cumulativeJitterStats.jitterStarved
        s.jitterNoInOrder = cumulativeJitterStats.jitterNoInOrder
        s.jitterOutOfOrderRenderRejects = cumulativeJitterStats.jitterOutOfOrderRenderRejects
        return s
    }

    func dispose() {
        stopTransition()
        stopWatchdog()
    }

    // MARK: - Private

    private func ensureSessionActive(frameSeq: Int?) {
        if isInSession { return }
        isInSession = true
        lastFrameReceivedTime = nowMs()
        hasReportedStall = false
        if conversationStartTime == 0 {
            conversationStartTime = nowMs()
        }
        startWatchdog()
        startPlaybackStats()
        if let seq = frameSeq {
            logger.info("Session started from animation frame seq=\(seq)")
        }
    }

    private func startWatchdog() {
        guard watchdogTask == nil else { return }
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                if !self.isInSession { continue }
                if self.isPlayingTransition { continue }
                let elapsed = Int(self.nowMs() - self.lastFrameReceivedTime)
                if elapsed > Self.stallTimeoutMs && !self.hasReportedStall {
                    self.logger.error("Data stream stalled: no frames received for \(elapsed)ms, falling back to idle")
                    self.hasReportedStall = true
                    self.isStalledFallback = true
                    self.startIdle()
                    self.config.onStreamStalled?()
                }
            }
        }
    }

    private func stopWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = nil
        hasReportedStall = false
        isStalledFallback = false
        stopPlaybackStats()
    }

    private func startPlaybackStats() {
        guard playbackStatsTask == nil else { return }
        resetPlaybackStats()
        playbackStatsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.reportPlaybackStats()
            }
        }
    }

    private func stopPlaybackStats() {
        playbackStatsTask?.cancel()
        playbackStatsTask = nil
        resetPlaybackStats()
    }

    private func resetPlaybackStats() {
        playbackFrameCount = 0
        playbackFrameTimestamps = []
        playbackGapCount = 0
        playbackExpectedSeq = -1
    }

    private func reportPlaybackStats() {
        if isPlayingTransition {
            resetPlaybackStats()
            return
        }
        if playbackFrameCount == 0 { return }

        let fps = playbackFrameCount
        let totalExpected = playbackFrameCount + playbackGapCount
        let lossRate: Double = totalExpected > 0 ? (Double(playbackGapCount) / Double(totalExpected)) * 100 : 0

        var jitter: Double = 0
        if playbackFrameTimestamps.count >= 2 {
            var intervals: [Double] = []
            for i in 1..<playbackFrameTimestamps.count {
                intervals.append(playbackFrameTimestamps[i] - playbackFrameTimestamps[i - 1])
            }
            let mean = intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.reduce(0) { $0 + pow($1 - mean, 2) } / Double(intervals.count)
            jitter = sqrt(variance)
        }

        logger.info("Playback stats: fps=\(fps), lossRate=\(String(format: "%.1f", lossRate))%, jitter=\(String(format: "%.1f", jitter))ms")

        conversationFrameCount += playbackFrameCount
        conversationLost += playbackGapCount
        conversationFpsReadings.append(fps)

        playbackFrameCount = 0
        playbackFrameTimestamps = []
        playbackGapCount = 0
    }

    private func reportConversationStats() {
        let hasPlaybackFrames = conversationFrameCount > 0
        let hasJitterStats = jitterStatsAnyNonZero(conversationJitterStats)
        if !hasPlaybackFrames && !hasJitterStats { return }

        let durationMs = conversationStartTime > 0 ? Int(nowMs() - conversationStartTime) : 0
        let avgFps: Int = conversationFpsReadings.isEmpty ? 0 :
            Int((Double(conversationFpsReadings.reduce(0, +)) / Double(conversationFpsReadings.count)).rounded())
        let totalExpected = conversationFrameCount + conversationLost
        let lossRate: Double = totalExpected > 0 ?
            Double((Double(conversationLost) / Double(totalExpected) * 100 * 10).rounded()) / 10 : 0
        let skipRate: Int = totalExpected > 0 ?
            Int((Double(conversationSkipped) / Double(totalExpected) * 100).rounded()) : 0

        let quality = conversationQuality
        let stallTotalMs = quality.stalls.reduce(0.0) { $0 + Self.stallRunDurationMs($1) }
        let stallMaxMs = quality.stalls.reduce(0.0) { max($0, Self.stallRunDurationMs($1)) }
        // Share of the round the picture spent frozen. Computed per round here
        // rather than left to the backend: dividing an aggregated stall metric
        // by an aggregated duration metric divides one distribution's P95 by
        // another's, which answers nothing. A ratio is only meaningful while
        // both numbers still belong to the same round.
        let stallRatePct: Double = durationMs > 0 ?
            (stallTotalMs / Double(durationMs) * 100 * 10).rounded() / 10 : 0

        // Variable-length detail travels as JSON strings: the log backend
        // flattens nested structures, and a flattened array of objects is
        // rejected outright.
        let stallEventsJson = Self.jsonString(quality.stalls.map { run in
            [
                "seq": run.waitingForSeq,
                "ms": Int(Self.stallRunDurationMs(run).rounded()),
                "ticks": run.ticks,
                // Whether the buffer was empty or merely missing the next
                // sequence. Both freeze the picture; only the first means
                // nothing was arriving.
                "starved": run.startedStarved,
            ] as [String: Any]
        })
        let skippedSeqsJson = Self.jsonString(quality.skipped.map { range in
            range.from == range.to ? "\(range.from)" : "\(range.from)-\(range.to)"
        })

        Telemetry.event("rtc_playback_stats", level: .info, [
            "provider": config.providerName,
            "avg_fps": avgFps,
            "frame_count": conversationFrameCount,
            "frames_lost": conversationLost,
            "frames_recovered": conversationRecovered,
            "frames_dropped": conversationDropped,
            "skipped_frames": conversationSkipped,
            "skip_rate": skipRate,
            "loss_rate": lossRate,
            "duration_ms": durationMs,
            // How the round ended, and whether its final frames reached the screen.
            "end_reason": quality.endReason.rawValue,
            "tail_intact": quality.tailIntact ?? false,
            "tail_discarded": quality.tailDiscarded,
            // Transitions: expected versus what actually played. A shortfall on
            // the start transition is the visible jump into speech.
            "start_transition_expected": quality.startTransitionExpected,
            "start_transition_rendered": quality.startTransitionRendered,
            "end_transition_expected": quality.endTransitionExpected,
            "end_transition_rendered": quality.endTransitionRendered,
            // Freezes: playback slots that rendered nothing while awaiting a frame.
            "stall_count": quality.stalls.count,
            "stall_total_ms": Int(stallTotalMs.rounded()),
            "stall_max_ms": Int(stallMaxMs.rounded()),
            "stall_rate_pct": stallRatePct,
            "stall_events": stallEventsJson,
            // Sequences abandoned without ever rendering.
            "skipped_seqs": skippedSeqsJson,
            "jitter_drop_stale": conversationJitterStats.jitterDropStale,
            "jitter_drop_late": conversationJitterStats.jitterDropLate,
            "jitter_drop_overflow": conversationJitterStats.jitterDropOverflow,
            "jitter_prune_stale": conversationJitterStats.jitterPruneStale,
            "jitter_skip_events": conversationJitterStats.jitterSkipEvents,
            "jitter_skip_frames": conversationJitterStats.jitterSkipFrames,
            "jitter_starved": conversationJitterStats.jitterStarved,
            "jitter_no_in_order": conversationJitterStats.jitterNoInOrder,
            "jitter_out_of_order_render_rejects": conversationJitterStats.jitterOutOfOrderRenderRejects,
        ])

        recordPlaybackMetrics(
            durationMs: durationMs,
            avgFps: avgFps,
            skipRate: skipRate,
            stallTotalMs: stallTotalMs,
            stallMaxMs: stallMaxMs,
            stallRatePct: stallRatePct
        )

        cumulativeTotalFrames += conversationFrameCount
        cumulativeLost += conversationLost
        cumulativeRecovered += conversationRecovered
        cumulativeDropped += conversationDropped
        cumulativeFpsReadings.append(contentsOf: conversationFpsReadings)
        mergeJitterStats(into: &cumulativeJitterStats, from: conversationJitterStats)

        conversationFrameCount = 0
        conversationLost = 0
        conversationRecovered = 0
        conversationDropped = 0
        conversationSkipped = 0
        conversationFpsReadings = []
        conversationStartTime = 0
        conversationJitterStats = JitterStatsCounters()
        conversationQuality = QualityStats()
        lastRenderedPayload = nil
    }

    /// Emit the round's playback quality as metric data points.
    ///
    /// Labels stay low-cardinality, so these answer "how is playback doing
    /// overall" — P95 stall rate, fps distribution, whether a release made
    /// things worse. They cannot answer "what happened in round X": metrics are
    /// aggregated by label, and a single observation's identity is gone by the
    /// time it lands. The event and trace channels carry that.
    private func recordPlaybackMetrics(
        durationMs: Int,
        avgFps: Int,
        skipRate: Int,
        stallTotalMs: Double,
        stallMaxMs: Double,
        stallRatePct: Double
    ) {
        let quality = conversationQuality
        let labels: [String: Telemetry.Label] = [
            "provider": .string(config.providerName),
            "end_reason": .string(quality.endReason.rawValue),
        ]

        Telemetry.recordMetric("rtc_playback_duration_ms", Double(durationMs), labels: labels)
        Telemetry.recordMetric("rtc_playback_avg_fps", Double(avgFps), labels: labels)
        Telemetry.recordMetric("rtc_playback_frame_count", Double(conversationFrameCount), labels: labels)
        Telemetry.recordMetric("rtc_playback_skipped_frames", Double(conversationSkipped), labels: labels)
        Telemetry.recordMetric("rtc_playback_skip_rate_pct", Double(skipRate), labels: labels)
        Telemetry.recordMetric("rtc_playback_stall_count", Double(quality.stalls.count), labels: labels)
        Telemetry.recordMetric("rtc_playback_stall_total_ms", stallTotalMs, labels: labels)
        Telemetry.recordMetric("rtc_playback_stall_max_ms", stallMaxMs, labels: labels)
        // The share, not just the totals: a 500ms freeze means something very
        // different in a 2s round than in a 60s one, and only the ratio makes
        // those two comparable in one distribution.
        Telemetry.recordMetric("rtc_playback_stall_rate_pct", stallRatePct, labels: labels)
        Telemetry.recordMetric("rtc_playback_tail_discarded", Double(quality.tailDiscarded), labels: labels)
        // Shortfall rather than the raw counts: zero is the healthy value, so
        // any non-zero reading is a transition the viewer saw cut short.
        Telemetry.recordMetric(
            "rtc_playback_start_transition_missing",
            Double(max(0, quality.startTransitionExpected - quality.startTransitionRendered)),
            labels: labels
        )
        Telemetry.recordMetric(
            "rtc_playback_end_transition_missing",
            Double(max(0, quality.endTransitionExpected - quality.endTransitionRendered)),
            labels: labels
        )
    }

    /// Duration of one stall run. Taken from the clock rather than the tick
    /// count: the clock stops while the buffer is starved, so counting slots
    /// would understate exactly the freezes that matter most.
    private static func stallRunDurationMs(_ run: StallRun) -> Double {
        max(0, run.endedAt - run.startedAt)
    }

    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    // MARK: - Jitter buffer

    private func bufferFrame(_ protobufData: Data, seq: Int, isRecovered: Bool) {
        if lastRenderedFrameSeq >= 0 && seq <= lastRenderedFrameSeq {
            conversationJitterStats.jitterDropStale += 1
            conversationDropped += 1
            return
        }
        if bufferNextSeq >= 0 && seq < bufferNextSeq {
            conversationJitterStats.jitterDropLate += 1
            conversationDropped += 1
            return
        }
        if frameBuffer[seq] != nil { return }

        frameBuffer[seq] = BufferedFrame(protobufData: protobufData, seq: seq, receivedAt: nowMs(), isRecovered: isRecovered)

        if frameBuffer.count > Self.bufferMaxSize {
            let oldestSeq = frameBuffer.keys.min() ?? 0
            frameBuffer.removeValue(forKey: oldestSeq)
            conversationJitterStats.jitterDropOverflow += 1
            conversationDropped += 1
            trackMetric("rtc_jitter_buffer_overflow", ["dropped_seq": oldestSeq])
        }

        switch bufferState {
        case .direct:
            setBufferState(.filling)
            if bufferNextSeq < 0 { bufferNextSeq = seq }
            logger.info("Jitter buffer: filling (first frame seq=\(seq))")
            if hasFilledEnoughToStart(latestSeq: seq) {
                startBufferDrain()
            }
        case .filling:
            if hasFilledEnoughToStart(latestSeq: seq) {
                startBufferDrain()
            }
        case .starved:
            startBufferDrain()
        case .draining:
            // A frame the drain loop is *already waiting on* — it spun a slot
            // without rendering, so the picture is frozen and this frame is
            // late (an ALR packet recovering a loss ~20ms on, say). Rendering
            // it right away shortens a freeze that is already happening.
            //
            // An open stall run is what says the loop is waiting. Without that
            // check — matching only on the sequence and an armed timer — every
            // frame qualifies, because bufferNextSeq advances past each render
            // and the timer is always armed while draining. Each frame would
            // then be drawn the moment it arrived instead of at its slot, so
            // the buffer would never hold anything back and playback would
            // simply replay the network's arrival pattern. Absorbing exactly
            // that is what the buffer is for.
            //
            // Never while a transition is playing: the clock's slots belong to
            // it, and rendering here would put a second writer on the renderer.
            if seq == bufferNextSeq,
               playbackTask != nil,
               !isPlayingTransition,
               conversationQuality.openStall != nil {
                stopPlaybackClock()
                // The frame fills the slot it was already due at, so the grid
                // advances exactly as it would have on the tick this replaces.
                scheduleNextSlot(rendered: drainBufferFrame())
            }
        }
    }

    /// Whether enough of the round has arrived to start draining.
    ///
    /// The measure is how far the *server* has got, not how many frames happen
    /// to be in hand: sequence numbers start at 0 and advance one per frame
    /// interval, so seq N having been sent means N intervals of this round have
    /// already elapsed — and the audio, which the driving service paces to
    /// match, is that far in too.
    ///
    /// Counting frames instead (`count >= bufferInitialFill`) gives the same
    /// answer whenever nothing is lost, but not otherwise. If seq 0 and 1 are
    /// both dropped and seq 2 is the first to land, the buffer holds one frame
    /// and the old check waited for seq 3 — spending another interval filling
    /// up while the audio was already two intervals ahead. The picture then
    /// trails the sound for the rest of the round, since the drain grid never
    /// catches up. Filling a buffer is worth an interval only when there is
    /// time to spare, which is exactly what a lossy start does not have.
    private func hasFilledEnoughToStart(latestSeq: Int) -> Bool {
        latestSeq >= Self.bufferInitialFill - 1
    }

    private func dropStaleBufferedFrames() {
        if frameBuffer.isEmpty { return }
        let minAllowedSeq = max(bufferNextSeq, lastRenderedFrameSeq + 1)
        if minAllowedSeq < 0 { return }
        var dropped = 0
        for seq in Array(frameBuffer.keys) where seq < minAllowedSeq {
            frameBuffer.removeValue(forKey: seq)
            dropped += 1
        }
        if dropped > 0 {
            conversationJitterStats.jitterPruneStale += dropped
            conversationDropped += dropped
        }
    }

    private func findLowestBufferedSeqAtOrAfter(_ minSeq: Int) -> Int? {
        var candidate = Int.max
        for seq in frameBuffer.keys where seq >= minSeq && seq < candidate {
            candidate = seq
        }
        return candidate == Int.max ? nil : candidate
    }

    private func startBufferDrain() {
        setBufferState(.draining)
        if bufferNextSeq < 0 {
            bufferNextSeq = frameBuffer.keys.min() ?? -1
        }
        logger.info("Jitter buffer: draining (\(frameBuffer.count) frames buffered)")
        // The start transition normally still has its extra frame to play when
        // draining begins, so the clock is already running and this is a no-op;
        // the stream then falls onto the grid the transition established. Only
        // a round that never ran a transition starts the clock here.
        startPlaybackClock()
    }

    /// Render whatever the current slot is owed from the jitter buffer.
    /// - Returns: whether a frame actually reached the screen.
    @discardableResult
    private func drainBufferFrame() -> Bool {
        if bufferState != .draining { return false }

        let renderedBefore = renderedFrameCount

        dropStaleBufferedFrames()

        if let frame = frameBuffer[bufferNextSeq] {
            // A frame rendering normally ends any stall run in progress.
            closeStallRun()
            renderBufferedFrame(frame)
            frameBuffer.removeValue(forKey: bufferNextSeq)
            bufferNextSeq += 1
        } else if !frameBuffer.isEmpty {
            guard let nextSeq = findLowestBufferedSeqAtOrAfter(bufferNextSeq) else {
                conversationJitterStats.jitterNoInOrder += 1
                enterStarvedState()
                return false
            }
            let nextFrame = frameBuffer[nextSeq]!
            let waitTime = nowMs() - nextFrame.receivedAt
            if waitTime > Double(config.maxBufferDelayMs) {
                let gap = max(0, nextSeq - bufferNextSeq)
                if gap > 0 {
                    conversationQuality.skipped.append(
                        SkippedRange(from: bufferNextSeq, to: nextSeq - 1, at: nowMs())
                    )
                }
                // Giving up on the missing frame also ends the stall it caused.
                closeStallRun()
                playbackGapCount += gap
                conversationSkipped += gap
                conversationJitterStats.jitterSkipEvents += 1
                conversationJitterStats.jitterSkipFrames += gap
                renderBufferedFrame(nextFrame)
                frameBuffer.removeValue(forKey: nextSeq)
                bufferNextSeq = nextSeq + 1
            } else {
                // Waiting for the missing frame: this slot renders nothing, so
                // the picture is frozen on the previous frame for another
                // interval.
                noteStallTick()
            }
        } else {
            // Buffer empty — this slot renders nothing either, so the picture
            // is frozen exactly as it is when waiting on a gap. Recording it
            // here is what the stall counters would otherwise miss: the clock
            // stops when the buffer starves, so nothing else would ever mark
            // this freeze.
            noteStallTick()
            enterStarvedState()
            return false
        }

        return renderedFrameCount > renderedBefore
    }

    // MARK: - Playback clock

    /// Start the single playback clock if it is not already running.
    ///
    /// - Parameter resumeGrid: continue the grid the stream was already on
    ///   instead of re-anchoring to now. Used when an end transition takes
    ///   over from streaming playback: generation takes time, and anchoring
    ///   afresh put the transition's opening frame wherever that landed —
    ///   7-13ms after the last stream frame, against a 40ms interval.
    private func startPlaybackClock(resumeGrid: Bool = false) {
        if playbackTask != nil { return }

        if resumeGrid {
            let now = nowMs()
            let interval = Self.frameIntervalMs
            // Generation ate part of a slot — sometimes more than one — so the
            // grid may already point into the past. Step to the first slot
            // still ahead of us and wait for it.
            //
            // Only worth resuming while the grid is still current. More than a
            // slot behind means nothing was pacing playback (the buffer was
            // disabled, or the round never started one), so there is no cadence
            // to line up with and the transition simply starts now.
            let behind = now - playbackGridSlot
            if behind < interval {
                let target = behind >= 0 ? playbackGridSlot + interval : playbackGridSlot
                playbackGridSlot = target
                scheduleTick(afterMs: target - now)
                return
            }
            // Fall through and re-anchor.
        }

        playbackGridSlot = nowMs()
        playbackTick()
    }

    private func stopPlaybackClock() {
        playbackTask?.cancel()
        playbackTask = nil
    }

    private func scheduleTick(afterMs delay: TimeInterval) {
        let requested = max(0, delay)
        let armedAt = nowMs()
        playbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(requested * 1_000_000))
            guard let self, !Task.isCancelled else { return }
            // How much later than asked the slot actually fired. Sleep only
            // guarantees a floor, and the wake still has to get back onto the
            // main actor behind whatever else is queued there.
            PlaybackProbe.shared.recordSlot(
                requestedMs: requested,
                actualMs: self.nowMs() - armedAt
            )
            self.playbackTick()
        }
    }

    /// One slot of the playback clock: render exactly one thing, then decide
    /// when the next slot is due.
    private func playbackTick() {
        playbackTask = nil

        let rendered = isPlayingTransition ? playTransitionFrame() : drainBufferFrame()

        // A booked end transition waits out the slots still owed to the queued
        // frames (the jitter buffer's initial fill) before taking over. Only a
        // slot that actually put a frame on screen counts against the debt: an
        // empty one repaid nothing, and letting it count would hand over early
        // — exactly the cut-short ending the debt exists to prevent.
        if pendingEndTransitionFrames != nil {
            if rendered { endTransitionSlotsOwed -= 1 }
            // A slot that rendered nothing while still draining is waiting on a
            // frame that has not arrived yet — it is coming, so keep waiting.
            // Only a starved buffer means nothing more will come: the round has
            // ended, so the debt cannot be repaid.
            let nothingLeftToPlay = bufferState != .draining
            if endTransitionSlotsOwed <= 0 || nothingLeftToPlay {
                beginEndTransition()
                return
            }
        }

        scheduleNextSlot(rendered: rendered)
    }

    private func scheduleNextSlot(rendered: Bool) {
        if !isPlayingTransition && bufferState != .draining {
            // Nothing left to pace: no transition is running and the buffer is
            // not draining (starved, flushed, or back to idle). Whichever
            // source resumes restarts the clock.
            return
        }

        let now = nowMs()
        let interval = Self.frameIntervalMs

        let delay: TimeInterval
        if rendered {
            // Resynchronise when the grid has fallen behind — a backgrounded
            // app or a blocked main thread — so the backlog does not fire back
            // to back. Catching up would flush the remaining frames in an
            // instant, which looks exactly like the jump a transition exists
            // to smooth over.
            let base = max(playbackGridSlot, now - interval)
            playbackGridSlot = base + interval
            delay = max(0, playbackGridSlot - now)
        } else {
            // The slot stays where it is and the frame that fills it is still
            // due there. Only the retry is pushed out: re-running immediately
            // would spin the loop at zero delay.
            delay = interval
        }

        scheduleTick(afterMs: delay)
    }

    private func renderBufferedFrame(_ frame: BufferedFrame) {
        if lastRenderedFrameSeq >= 0 && frame.seq <= lastRenderedFrameSeq {
            conversationJitterStats.jitterOutOfOrderRenderRejects += 1
            conversationDropped += 1
            return
        }
        isIdle = false
        renderer.renderFromProtobuf(frame.protobufData)
        lastRenderedPayload = frame.protobufData
        lastRenderedFrameSeq = frame.seq
        renderedFrameCount += 1
        if frame.isRecovered { conversationRecovered += 1 }
        logRenderedFrame(source: "buffer", seq: frame.seq, isRecovered: frame.isRecovered)

        playbackFrameTimestamps.append(nowMs())
        playbackFrameCount += 1
    }

    private func flushBuffer() {
        frameBuffer.removeAll()
        setBufferState(.direct)
        bufferNextSeq = -1
        // Only stop the clock when no transition still needs it: a transition
        // flushes the buffer as it takes over, and stopping here would kill the
        // very slots it is about to be played on.
        if !isPlayingTransition {
            stopPlaybackClock()
        }
    }

    // MARK: - Transition playback

    /// Render this slot's transition frame.
    /// - Returns: whether something actually reached the screen.
    @discardableResult
    private func playTransitionFrame() -> Bool {
        if !isPlayingTransition || transitionFrameIndex >= transitionFrames.count {
            let wasTransitioningToIdle = isTransitioningToIdle
            isPlayingTransition = false
            isTransitioningToIdle = false
            transitionFrames = []
            transitionFrameIndex = 0
            logger.info("Transition playback complete")
            if wasTransitioningToIdle {
                logger.info("Starting idle animation after transition")
                // This is where a normal round actually finishes: the end
                // transition has played out and the avatar is back to idle.
                // Report here rather than in startIdle(), which this path never
                // calls — only the abnormal endings (stall fallback, bare idle
                // packet) go through that.
                closeStallRun()
                reportConversationStats()
                // Reset session tracking before going idle. Otherwise the next
                // conversation's start-transition packet — which arrives before the
                // first animation frame (and thus before resetTracking runs) — hits
                // the "playback already started" guard (isInSession + lastRenderedSeq)
                // and gets dropped, leaving the next conversation with no start
                // transition (visible jump on the opening frame).
                isInSession = false
                lastRenderedFrameSeq = -1
                hasHandledTransitionStart = false
                renderer.renderFrame(nil, startIdle: true)
                logRenderedFrame(source: "idle", seq: nil, isRecovered: false)
                return true
            }

            // A start transition just ran out, and this slot is still unfilled.
            // The stream is what continues the motion, so hand the slot
            // straight to the buffer instead of ending the tick: the
            // transition's last frame and the stream's first are consecutive
            // frames of one sequence and belong one interval apart. Returning
            // here instead would leave this slot empty and open a two-interval
            // hole exactly at the hand-over.
            return drainBufferFrame()
        }
        if !renderer.isReady() {
            isPlayingTransition = false
            isTransitioningToIdle = false
            return false
        }
        let frame = transitionFrames[transitionFrameIndex]
        isIdle = false
        renderer.renderFrame(frame, startIdle: false)
        logRenderedFrame(source: "transition", seq: nil, isRecovered: false)
        transitionFrameIndex += 1

        // Counted per frame rather than from the generated length: a transition
        // can be cut short (the start one is interrupted by the first animation
        // frame), and the gap between expected and rendered is the visible jump.
        let now = nowMs()
        if isTransitioningToIdle {
            conversationQuality.endTransitionRendered += 1
            if conversationQuality.endTransitionBeganAt == 0 {
                conversationQuality.endTransitionBeganAt = now
            }
        } else {
            conversationQuality.startTransitionRendered += 1
            if conversationQuality.startTransitionBeganAt == 0 {
                conversationQuality.startTransitionBeganAt = now
            }
            // Moves with each frame, so it ends up at the last one played — the
            // start transition can be cut short, and that final frame is where
            // the animation frames take over.
            //
            // One interval past that render, not the render itself: the frame
            // still occupies its own slot, and the transition is over only when
            // the slot ends and the stream's first frame is due. Nothing can
            // claim that slot early — pre-emption is barred while a transition
            // is playing, and the flag only clears on the following tick — so
            // the interval is always served in full.
            //
            // Ending at the render instead understated the transition by a
            // frame and, because this same instant opens the speaking span,
            // padded that span by the same 40ms: a round streaming a clean
            // 25fps reported 24.
            conversationQuality.startTransitionEndedAt = now + Self.frameIntervalMs
        }


        return true
    }

    // MARK: - Helpers

    private func setBufferState(_ state: BufferState) {
        bufferState = state
    }

    // MARK: - Stall runs

    /// Record a slot that rendered nothing, opening a stall run or extending
    /// the one already open.
    private func noteStallTick() {
        let now = nowMs()
        if conversationQuality.openStall != nil {
            conversationQuality.openStall?.ticks += 1
            return
        }
        conversationQuality.openStall = StallRun(
            waitingForSeq: bufferNextSeq,
            startedAt: now,
            ticks: 1,
            startedStarved: frameBuffer.isEmpty
        )
    }

    /// Close the stall run in progress, if any — a frame reached the screen.
    private func closeStallRun() {
        guard var open = conversationQuality.openStall else { return }
        open.endedAt = nowMs()
        conversationQuality.stalls.append(open)
        conversationQuality.openStall = nil
    }

    /// Whether `protobufData` carries the frame that is currently on screen.
    /// Used for the tail check: loss is detected from a gap to the *following*
    /// frame, and the round's final frame has none, so comparing the
    /// transition-end packet's payload is the only way to tell whether the tail
    /// made it.
    private func isSameFrameAsLastRendered(_ protobufData: Data) -> Bool {
        guard let last = lastRenderedPayload else { return false }
        return last == protobufData
    }

    private var bufferStateName: String {
        switch bufferState {
        case .direct: return "direct"
        case .filling: return "filling"
        case .draining: return "draining"
        case .starved: return "starved"
        }
    }

    private func enterStarvedState() {
        let prev = bufferState
        setBufferState(.starved)
        if prev == .starved { return }
        conversationJitterStats.jitterStarved += 1
        trackMetric("rtc_jitter_buffer_starved")
    }

    private func trackMetric(_ metric: String, _ props: [String: Sendable] = [:]) {
        var merged = props
        merged["provider"] = config.providerName
        merged["buffered_frames"] = frameBuffer.count
        merged["next_expected_seq"] = bufferNextSeq
        merged["last_rendered_seq"] = lastRenderedFrameSeq
        merged["max_buffer_delay_ms"] = config.maxBufferDelayMs
        Telemetry.metric(metric, merged)
    }

    private func mergeJitterStats(into target: inout JitterStatsCounters, from source: JitterStatsCounters) {
        target.jitterDropStale += source.jitterDropStale
        target.jitterDropLate += source.jitterDropLate
        target.jitterDropOverflow += source.jitterDropOverflow
        target.jitterPruneStale += source.jitterPruneStale
        target.jitterSkipEvents += source.jitterSkipEvents
        target.jitterSkipFrames += source.jitterSkipFrames
        target.jitterStarved += source.jitterStarved
        target.jitterNoInOrder += source.jitterNoInOrder
        target.jitterOutOfOrderRenderRejects += source.jitterOutOfOrderRenderRejects
    }

    private func jitterStatsAnyNonZero(_ s: JitterStatsCounters) -> Bool {
        s.jitterDropStale > 0 || s.jitterDropLate > 0 || s.jitterDropOverflow > 0 ||
        s.jitterPruneStale > 0 || s.jitterSkipEvents > 0 || s.jitterSkipFrames > 0 ||
        s.jitterStarved > 0 || s.jitterNoInOrder > 0 || s.jitterOutOfOrderRenderRejects > 0
    }

    private func logRenderedFrame(source: String, seq: Int?, isRecovered: Bool) {
        let now = nowMs()
        // Gap since the previous frame reached the screen. This is the number
        // the single clock exists to hold at one interval: every render goes
        // through here, so the series covers the transition→stream hand-over
        // and the stream→end-transition hand-over, which is exactly where two
        // independently-paced chains used to leave a short slot.
        let gap = lastRenderLogAt > 0 ? now - lastRenderLogAt : 0
        lastRenderLogAt = now
        logger.info("Rendered frame: source=\(source), seq=\(seq.map(String.init) ?? "n/a")\(isRecovered ? " [RECOVERED]" : ""), gap=\(Int(gap.rounded()))ms")
        PlaybackProbe.shared.record(source: source, seq: seq, gapMs: gap, isRecovered: isRecovered)
    }

    private func nowMs() -> TimeInterval {
        Date().timeIntervalSince1970 * 1000
    }
}
