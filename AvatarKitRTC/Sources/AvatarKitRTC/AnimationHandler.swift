import Foundation
import AvatarKit

/// Renderer abstraction injected by AvatarPlayer. Adapts AvatarView's
/// single-frame APIs to the surface AnimationHandler needs. Kept as a
/// protocol so AnimationHandler stays platform-agnostic (mirrors web's
/// `AvatarRenderer` interface).
@MainActor protocol AvatarRendererAdapter: AnyObject {
    func renderFromProtobuf(_ data: Data) async
    func renderFrame(_ frame: Frame?, startIdle: Bool) async
    func generateTransitionFromProtobuf(_ data: Data, frameCount: Int) async -> [Frame]
    func isReady() -> Bool
}

/// Configuration for AnimationHandler. Matches web's AnimationHandlerConfig.
struct AnimationHandlerConfig {
    var transitionStartFrameCount: Int = 8
    var transitionEndFrameCount: Int = 12
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
    private var transitionTask: Task<Void, Never>?

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
    private var bufferDrainTask: Task<Void, Never>?
    private var bufferLastDrainTime: TimeInterval = 0
    private static let bufferMaxSize = 4
    private static let bufferInitialFill = 2
    private static let bufferFrameIntervalMs: TimeInterval = 40

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
        if isPlayingTransition {
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

        Task { @MainActor [weak self, renderer] in
            await renderer.renderFromProtobuf(protobufData)
            self?.logRenderedFrame(source: "direct", seq: frameSeq, isRecovered: isRecovered)
        }

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

        let frames = frameCount ?? config.transitionStartFrameCount
        logger.info("Generating \(frames) transition frames to target")
        isGeneratingStartTransition = true

        Task { @MainActor [weak self, renderer] in
            guard let self else { return }
            let transitionFrames = await renderer.generateTransitionFromProtobuf(protobufData, frameCount: frames)
            self.logger.info("Generated \(transitionFrames.count) transition frames")
            self.isPlayingTransition = true
            self.isTransitioningToIdle = false
            self.transitionFrames = transitionFrames
            self.transitionFrameIndex = 0
            self.playTransitionFrame()
            self.isGeneratingStartTransition = false
        }
    }

    /// Handle the speaking-to-idle transition packet.
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
            Task { @MainActor [renderer] in await renderer.renderFrame(nil, startIdle: true) }
            logRenderedFrame(source: "idle", seq: nil, isRecovered: false)
            return
        }

        hasHandledTransitionEnd = true
        flushBuffer()

        let frames = frameCount ?? config.transitionEndFrameCount
        logger.info("Generating \(frames) reverse transition frames to idle")
        isGeneratingEndTransition = true

        Task { @MainActor [weak self, renderer] in
            guard let self else { return }
            let transitionFrames = await renderer.generateTransitionFromProtobuf(protobufData, frameCount: frames)
            self.logger.info("Generated \(transitionFrames.count) transition frames, reversing for playback")
            let reversed = Array(transitionFrames.reversed())
            self.isPlayingTransition = true
            self.isTransitioningToIdle = true
            self.transitionFrames = reversed
            self.transitionFrameIndex = 0
            self.playTransitionFrame()
            self.isGeneratingEndTransition = false
        }
    }

    /// Switch to idle animation immediately. Reports conversation stats first.
    func startIdle() {
        reportConversationStats()
        isInSession = false
        hasReportedStall = false
        Task { @MainActor [renderer] in await renderer.renderFrame(nil, startIdle: true) }
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
        transitionTask?.cancel()
        transitionTask = nil
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

        Telemetry.event("rtc_playback_stats", level: .info, [
            "provider": config.providerName,
            "avg_fps": avgFps,
            "frame_count": conversationFrameCount,
            "frames_lost": conversationLost,
            "frames_recovered": conversationRecovered,
            "frames_dropped": conversationDropped,
            "loss_rate": lossRate,
            "duration_ms": durationMs,
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
        conversationFpsReadings = []
        conversationStartTime = 0
        conversationJitterStats = JitterStatsCounters()
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
            if frameBuffer.count >= Self.bufferInitialFill {
                startBufferDrain()
            }
        case .filling:
            if frameBuffer.count >= Self.bufferInitialFill {
                startBufferDrain()
            }
        case .starved:
            startBufferDrain()
        case .draining:
            break
        }
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
        bufferLastDrainTime = nowMs()
        drainBufferFrame()
    }

    private func drainBufferFrame() {
        bufferDrainTask = nil
        if bufferState != .draining { return }

        dropStaleBufferedFrames()

        if let frame = frameBuffer[bufferNextSeq] {
            renderBufferedFrame(frame)
            frameBuffer.removeValue(forKey: bufferNextSeq)
            bufferNextSeq += 1
        } else if !frameBuffer.isEmpty {
            guard let nextSeq = findLowestBufferedSeqAtOrAfter(bufferNextSeq) else {
                conversationJitterStats.jitterNoInOrder += 1
                enterStarvedState()
                return
            }
            let nextFrame = frameBuffer[nextSeq]!
            let waitTime = nowMs() - nextFrame.receivedAt
            if waitTime > Double(config.maxBufferDelayMs) {
                let gap = max(0, nextSeq - bufferNextSeq)
                playbackGapCount += gap
                conversationJitterStats.jitterSkipEvents += 1
                conversationJitterStats.jitterSkipFrames += gap
                renderBufferedFrame(nextFrame)
                frameBuffer.removeValue(forKey: nextSeq)
                bufferNextSeq = nextSeq + 1
            }
        } else {
            enterStarvedState()
            return
        }

        let now = nowMs()
        let nextTarget = bufferLastDrainTime + Self.bufferFrameIntervalMs
        let delay = max(0, nextTarget - now)
        bufferLastDrainTime = nextTarget
        bufferDrainTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000))
            self?.drainBufferFrame()
        }
    }

    private func renderBufferedFrame(_ frame: BufferedFrame) {
        if lastRenderedFrameSeq >= 0 && frame.seq <= lastRenderedFrameSeq {
            conversationJitterStats.jitterOutOfOrderRenderRejects += 1
            conversationDropped += 1
            return
        }
        Task { @MainActor [renderer] in await renderer.renderFromProtobuf(frame.protobufData) }
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
        bufferLastDrainTime = 0
        bufferDrainTask?.cancel()
        bufferDrainTask = nil
    }

    // MARK: - Transition playback

    private func playTransitionFrame() {
        if !isPlayingTransition || transitionFrameIndex >= transitionFrames.count {
            let wasTransitioningToIdle = isTransitioningToIdle
            isPlayingTransition = false
            isTransitioningToIdle = false
            transitionFrames = []
            transitionFrameIndex = 0
            transitionTask?.cancel()
            transitionTask = nil
            logger.info("Transition playback complete")
            if wasTransitioningToIdle {
                logger.info("Starting idle animation after transition")
                Task { @MainActor [renderer] in await renderer.renderFrame(nil, startIdle: true) }
                logRenderedFrame(source: "idle", seq: nil, isRecovered: false)
            }
            return
        }
        if !renderer.isReady() {
            isPlayingTransition = false
            isTransitioningToIdle = false
            return
        }
        let frame = transitionFrames[transitionFrameIndex]
        Task { @MainActor [renderer] in await renderer.renderFrame(frame, startIdle: false) }
        logRenderedFrame(source: "transition", seq: nil, isRecovered: false)
        transitionFrameIndex += 1

        transitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 40_000_000)
            guard let self, self.isPlayingTransition else { return }
            self.playTransitionFrame()
        }
    }

    // MARK: - Helpers

    private func setBufferState(_ state: BufferState) {
        bufferState = state
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
        logger.info("Rendered frame: source=\(source), seq=\(seq.map(String.init) ?? "n/a")\(isRecovered ? " [RECOVERED]" : "")")
    }

    private func nowMs() -> TimeInterval {
        Date().timeIntervalSince1970 * 1000
    }
}
