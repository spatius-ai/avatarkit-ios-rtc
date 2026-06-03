import Foundation
import AvatarKit

/// Configuration for AvatarPlayer.
public struct AvatarPlayerOptions: Sendable {
    public var logLevel: RTCLogLevel
    public var enableJitterBuffer: Bool
    public var maxBufferDelayMs: Int

    public init(
        logLevel: RTCLogLevel = .warning,
        enableJitterBuffer: Bool = true,
        maxBufferDelayMs: Int = 80
    ) {
        self.logLevel = logLevel
        self.enableJitterBuffer = enableJitterBuffer
        self.maxBufferDelayMs = maxBufferDelayMs
    }
}

/// Player-level events fired to consumers.
public enum AvatarPlayerEvent: Sendable {
    case connected
    case disconnected
    case error(String)
    case stalled
    case connectionStateChanged(RTCConnectionState)
}

/// Unified avatar player for RTC-driven streaming.
///
/// 1:1 port of `@spatius/avatarkit-rtc`'s `AvatarPlayer.ts`. Drives the
/// AvatarView via single-frame APIs while delegating transport to an
/// `RTCProvider` implementation. iOS currently ships AgoraProvider only.
///
/// Lifecycle:
/// ```
/// let player = AvatarPlayer(provider: AgoraProvider(), avatarView: view)
/// try await player.connect(config)
/// try await player.publishAudio()    // optional, for mic talk-back
/// // ... animation/audio stream in over RTC ...
/// try await player.unpublishAudio()
/// await player.disconnect()
/// ```
@MainActor public final class AvatarPlayer {
    private static let DISCONNECT_TRANSITION_FRAMES = 12
    private static let DISCONNECT_TRANSITION_FRAME_INTERVAL_NS: UInt64 = 40_000_000

    private let logger = RTCLogger("AvatarPlayer")
    private let provider: RTCProvider
    private let avatarView: AvatarView
    private let providerName: String
    private var animationHandler: AnimationHandler!

    private var _isConnected = false
    public var isConnected: Bool { _isConnected }

    /// Cumulative jitter-buffer / playback statistics for the current
    /// connection. Read this from tests (or app code that wants a live view)
    /// to verify the state machine processed frames as expected: ordering,
    /// drops, skips, stalls.
    public var sessionSummary: AnimationSessionSummary {
        animationHandler.getSessionSummary()
    }

    private var hasPublishedAudio = false
    private var lastConnectionConfig: RTCConnectionConfig?
    private var isReconnecting = false

    // Session tracking
    private var hasActiveAnimationSession = false
    private var isTrackingPrimed = false
    private var connectStartTime: TimeInterval = 0
    private var sessionStartTime: TimeInterval = 0
    private var stallCount = 0
    private var reconnectCount = 0
    private var conversationCount = 0

    // Provider stream stats aggregation
    private struct StreamStatsAccumulator {
        var samples = 0
        var fpsSum: Double = 0
        var fpsMax: Double = 0
        var framesLost = 0
        var framesRecovered = 0
        var framesDropped = 0
        var framesOutOfOrder = 0
        var framesDuplicate = 0
    }
    private var streamStats = StreamStatsAccumulator()
    private var previousCounters: (lost: Int, recovered: Int, dropped: Int, oo: Int, dup: Int)?

    // Event subscribers
    private var subscribers: [(AvatarPlayerEvent) -> Void] = []

    public init(
        provider: RTCProvider,
        avatarView: AvatarView,
        options: AvatarPlayerOptions = AvatarPlayerOptions()
    ) {
        self.provider = provider
        self.avatarView = avatarView
        self.providerName = provider.name
        RTCLogger.currentLevel = options.logLevel

        // RTC takes over the speaking state only. AvatarKit's display-link
        // loop keeps running and drives the idle animation. The handover is
        // governed by AvatarView.renderFrame(_:startIdle:), which flips the
        // pure-rendering flag inside AnimationPlayer: while RTC has the
        // renderer the internal loop yields, and `renderFrame(nil, startIdle:
        // true)` releases ownership back to idle.

        let adapter = ViewRendererAdapter(view: avatarView)
        var handlerConfig = AnimationHandlerConfig()
        handlerConfig.enableJitterBuffer = options.enableJitterBuffer
        handlerConfig.maxBufferDelayMs = options.maxBufferDelayMs
        handlerConfig.providerName = providerName
        handlerConfig.onStreamStalled = { [weak self] in self?.handleStreamStalled() }
        self.animationHandler = AnimationHandler(renderer: adapter, config: handlerConfig)

        setupProviderEvents()
    }

    deinit {
        // AvatarView lifecycle is owned by the caller; no loop to resume since
        // we never paused it.
    }

    // MARK: - Public API

    public func connect(_ config: RTCConnectionConfig) async throws {
        guard !_isConnected else {
            throw AvatarPlayerError.alreadyConnected
        }

        lastConnectionConfig = config
        connectStartTime = nowMs()
        Telemetry.event("rtc_connect_start", level: .info, ["provider": providerName])

        do {
            await setupAnimationCallbacks()
            try await provider.connect(config)
            _isConnected = true
            sessionStartTime = nowMs()
            stallCount = 0
            reconnectCount = 0
            conversationCount = 0
            resetStreamStats()
            Telemetry.event("rtc_connect_success", level: .info, [
                "provider": providerName,
                "duration": Int(nowMs() - connectStartTime),
            ])
        } catch {
            Telemetry.event("rtc_connect_failed", level: .error, [
                "provider": providerName,
                "reason": String(describing: error),
                "duration": Int(nowMs() - connectStartTime),
            ])
            throw error
        }
    }

    public func disconnect() async {
        guard _isConnected else { return }

        if hasPublishedAudio {
            await unpublishAudio()
        }

        let summary = animationHandler.getSessionSummary()
        await provider.disconnect()
        animationHandler.dispose()
        // Soft transition back to idle then hand the renderer back to
        // AvatarKit. Mirrors AnimationHandler's server-driven end-transition
        // path so disconnect feels the same as a normal conversation end.
        let transitionFrames = await avatarView.generateTransitionToIdle(
            frameCount: Self.DISCONNECT_TRANSITION_FRAMES
        )
        for frame in transitionFrames {
            await avatarView.renderFrame(frame, startIdle: false)
            try? await Task.sleep(nanoseconds: Self.DISCONNECT_TRANSITION_FRAME_INTERVAL_NS)
        }
        await avatarView.renderFrame(nil, startIdle: true)
        _isConnected = false

        let sessionDuration = sessionStartTime > 0 ? Int(nowMs() - sessionStartTime) : 0

        Telemetry.event("rtc_session_summary", level: .info, [
            "provider": providerName,
            "total_duration_ms": sessionDuration,
            "total_frames": summary.totalFrames,
            "total_lost": summary.totalLost,
            "total_recovered": summary.totalRecovered,
            "total_dropped": summary.totalDropped,
            "avg_fps": summary.avgFps,
            "stall_count": stallCount,
            "reconnect_count": reconnectCount,
            "conversation_count": conversationCount,
            "stream_stats_samples": streamStats.samples,
            "stream_avg_fps": getStreamAverageFps(),
            "stream_max_fps": streamStats.fpsMax,
            "stream_frames_lost": streamStats.framesLost,
            "stream_frames_recovered": streamStats.framesRecovered,
            "stream_frames_dropped": streamStats.framesDropped,
            "stream_frames_out_of_order": streamStats.framesOutOfOrder,
            "stream_frames_duplicate": streamStats.framesDuplicate,
            "jitter_drop_stale": summary.jitterDropStale,
            "jitter_drop_late": summary.jitterDropLate,
            "jitter_drop_overflow": summary.jitterDropOverflow,
            "jitter_prune_stale": summary.jitterPruneStale,
            "jitter_skip_events": summary.jitterSkipEvents,
            "jitter_skip_frames": summary.jitterSkipFrames,
            "jitter_starved": summary.jitterStarved,
            "jitter_no_in_order": summary.jitterNoInOrder,
            "jitter_out_of_order_render_rejects": summary.jitterOutOfOrderRenderRejects,
        ])
        Telemetry.event("rtc_disconnected", level: .info, [
            "provider": providerName,
            "session_duration": sessionDuration,
        ])
    }

    public func publishAudio() async throws {
        guard _isConnected else { throw AvatarPlayerError.notConnected }
        try await provider.publishAudioTrack()
        hasPublishedAudio = true
    }

    public func unpublishAudio() async {
        guard hasPublishedAudio else { return }
        await provider.unpublishAudioTrack()
        hasPublishedAudio = false
    }

    /// Publish a synthetic PCM stream instead of the microphone.
    ///
    /// Analogous to web's `publishAudio(mediaStreamTrack)` — but on iOS the
    /// underlying provider receives raw bytes via `pushPCM(_:)`. Use this for
    /// integration tests or for replaying recorded utterances without
    /// pickup from the device's microphone.
    public func publishExternalPCM(sampleRate: Int = 16000, channels: Int = 1) async throws {
        guard _isConnected else { throw AvatarPlayerError.notConnected }
        try await provider.publishExternalPCM(sampleRate: sampleRate, channels: channels)
        hasPublishedAudio = true
    }

    /// Push a chunk of 16-bit signed PCM bytes into the previously started
    /// external audio source. Must be called after `publishExternalPCM`.
    public func pushPCM(_ data: Data) async {
        guard hasPublishedAudio else { return }
        await provider.pushExternalPCM(data)
    }

    public func reconnect() async throws {
        if isReconnecting {
            logger.warn("Already attempting reconnection, skipping")
            return
        }
        guard let config = lastConnectionConfig else {
            throw AvatarPlayerError.noPreviousConnection
        }
        isReconnecting = true
        reconnectCount += 1
        logger.info("Attempting reconnection...")

        let started = nowMs()
        Telemetry.event("rtc_reconnect_start", level: .info, ["provider": providerName])
        defer { isReconnecting = false }
        do {
            if _isConnected { await disconnect() }
            try await Task.sleep(nanoseconds: 500_000_000)
            try await connect(config)
            logger.info("Reconnection successful")
            Telemetry.event("rtc_reconnect_success", level: .info, [
                "provider": providerName,
                "duration": Int(nowMs() - started),
            ])
        } catch {
            logger.error("Reconnection failed: \(String(describing: error))")
            Telemetry.event("rtc_reconnect_failed", level: .error, [
                "provider": providerName,
                "reason": String(describing: error),
            ])
            throw error
        }
    }

    /// Subscribe to player events. Returns a token; call `unsubscribe(_:)` to remove.
    @discardableResult
    public func subscribe(_ handler: @escaping (AvatarPlayerEvent) -> Void) -> Int {
        subscribers.append(handler)
        return subscribers.count - 1
    }

    // MARK: - Private wiring

    private func setupAnimationCallbacks() async {
        let bridge = AnimationCallbacksBridge(player: self)
        await provider.subscribeAnimationTrack(bridge)
    }

    private func setupProviderEvents() {
        provider.setEventHandler { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected:
                self._isConnected = true
                self.emit(.connected)
            case .disconnected:
                self._isConnected = false
                self.hasActiveAnimationSession = false
                self.isTrackingPrimed = false
                self.animationHandler.startIdle()
                self.emit(.disconnected)
            case .error(let msg):
                Telemetry.event("rtc_error", level: .error, [
                    "provider": self.providerName,
                    "description": msg,
                ])
                self.emit(.error(msg))
            case .connectionStateChanged(let state):
                self.emit(.connectionStateChanged(state))
            }
        }
    }

    fileprivate func handleAnimationData(_ data: Data, metadata: AnimationFrameMetadata) {
        if !hasActiveAnimationSession {
            if !isTrackingPrimed {
                animationHandler.resetTracking()
            }
            hasActiveAnimationSession = true
            isTrackingPrimed = false
            if !metadata.isStart {
                logger.info("Session start inferred from frame seq=\(metadata.frameSeq.map(String.init) ?? "n/a")")
            }
        } else if metadata.isStart {
            logger.info("Ignoring duplicate session start frame seq=\(metadata.frameSeq.map(String.init) ?? "n/a")")
        }
        animationHandler.handleAnimationData(data, frameSeq: metadata.frameSeq, isRecovered: metadata.isRecovered)
    }

    fileprivate func handleTransition(_ data: Data, count: Int) {
        conversationCount += 1
        animationHandler.handleTransitionData(data, frameCount: count)
    }

    fileprivate func handleTransitionEnd(_ data: Data, count: Int) {
        animationHandler.handleTransitionToIdle(data, frameCount: count)
    }

    fileprivate func handleIdleStart() {
        // Idle packets can race with start-transition packets.
        if animationHandler.isInTransition {
            hasActiveAnimationSession = false
            isTrackingPrimed = false
            logger.info("Deferring idleStart while transition is active")
            return
        }
        hasActiveAnimationSession = false
        animationHandler.resetTracking()
        isTrackingPrimed = true
        animationHandler.startIdle()
    }

    fileprivate func handleStreamStats(_ stats: RTCStreamStats) {
        recordStreamStats(stats)
    }

    private func handleStreamStalled() {
        hasActiveAnimationSession = false
        isTrackingPrimed = false
        stallCount += 1
        Telemetry.event("rtc_stream_stalled", level: .warning, [
            "provider": providerName,
            "session_elapsed": sessionStartTime > 0 ? Int(nowMs() - sessionStartTime) : 0,
        ])
        emit(.stalled)
    }

    private func emit(_ event: AvatarPlayerEvent) {
        for sub in subscribers { sub(event) }
    }

    // MARK: - Stream stats aggregation

    private func resetStreamStats() {
        streamStats = StreamStatsAccumulator()
        previousCounters = nil
    }

    private func recordStreamStats(_ stats: RTCStreamStats) {
        let deltas = nonNegativeDeltas(stats)
        streamStats.samples += 1
        streamStats.fpsSum += stats.framesPerSec
        streamStats.fpsMax = max(streamStats.fpsMax, stats.framesPerSec)
        streamStats.framesLost += deltas.lost
        streamStats.framesRecovered += deltas.recovered
        streamStats.framesDropped += deltas.dropped
        streamStats.framesOutOfOrder += deltas.oo
        streamStats.framesDuplicate += deltas.dup

        if deltas.lost > 0 || deltas.recovered > 0 || deltas.dropped > 0 ||
            deltas.oo > 0 || deltas.dup > 0 {
            Telemetry.metric("rtc_stream_stats_anomaly", [
                "provider": providerName,
                "frames_per_sec": stats.framesPerSec,
                "total_frames": stats.totalFrames,
                "frames_sent": stats.framesSent,
                "frames_lost": deltas.lost,
                "frames_recovered": deltas.recovered,
                "frames_dropped": deltas.dropped,
                "frames_out_of_order": deltas.oo,
                "frames_duplicate": deltas.dup,
                "last_rendered_seq": stats.lastRenderedSeq,
            ])
        }
    }

    private func nonNegativeDeltas(_ stats: RTCStreamStats) -> (lost: Int, recovered: Int, dropped: Int, oo: Int, dup: Int) {
        let current = (
            lost: stats.framesLost,
            recovered: stats.framesRecovered,
            dropped: stats.framesDropped,
            oo: stats.framesOutOfOrder,
            dup: stats.framesDuplicate
        )
        guard let prev = previousCounters else {
            previousCounters = current
            return current
        }
        previousCounters = current
        func d(_ c: Int, _ p: Int) -> Int { c >= p ? c - p : c }
        return (
            d(current.lost, prev.lost),
            d(current.recovered, prev.recovered),
            d(current.dropped, prev.dropped),
            d(current.oo, prev.oo),
            d(current.dup, prev.dup)
        )
    }

    private func getStreamAverageFps() -> Double {
        guard streamStats.samples > 0 else { return 0 }
        return (streamStats.fpsSum / Double(streamStats.samples) * 10).rounded() / 10
    }

    private func nowMs() -> TimeInterval {
        Date().timeIntervalSince1970 * 1000
    }
}

public enum AvatarPlayerError: LocalizedError {
    case alreadyConnected
    case notConnected
    case noPreviousConnection

    public var errorDescription: String? {
        switch self {
        case .alreadyConnected: return "Already connected. Please disconnect first."
        case .notConnected: return "Not connected. Please call connect() first."
        case .noPreviousConnection: return "Cannot reconnect: no previous connection."
        }
    }
}

// MARK: - Adapters

/// Bridges AnimationHandler.AvatarRendererAdapter to AvatarKit.AvatarView.
@MainActor private final class ViewRendererAdapter: AvatarRendererAdapter {
    private weak var view: AvatarView?

    init(view: AvatarView) {
        self.view = view
    }

    func renderFromProtobuf(_ data: Data) async {
        do {
            try await view?.renderFromProtobuf(data)
        } catch {
            // Renderer logs internally; swallow to keep the playback loop alive.
        }
    }

    func renderFrame(_ frame: Frame?, startIdle: Bool) async {
        await view?.renderFrame(frame, startIdle: startIdle)
    }

    func generateTransitionToFrame(_ data: Data, frameCount: Int) async -> [Frame] {
        guard let view else { return [] }
        do {
            return try await view.generateTransitionToFrame(data, frameCount: frameCount)
        } catch {
            return []
        }
    }

    func generateTransitionToIdle(frameCount: Int) async -> [Frame] {
        guard let view else { return [] }
        return await view.generateTransitionToIdle(frameCount: frameCount)
    }

    func isReady() -> Bool {
        view != nil
    }
}

/// Bridges AnimationTrackCallbacks (provider-facing protocol) back to the
/// AvatarPlayer's fileprivate handlers.
@MainActor private final class AnimationCallbacksBridge: AnimationTrackCallbacks {
    private weak var player: AvatarPlayer?

    init(player: AvatarPlayer) {
        self.player = player
    }

    func onAnimationData(_ protobufData: Data, metadata: AnimationFrameMetadata) {
        player?.handleAnimationData(protobufData, metadata: metadata)
    }
    func onTransition(_ protobufData: Data, transitionFrameCount: Int) {
        player?.handleTransition(protobufData, count: transitionFrameCount)
    }
    func onTransitionEnd(_ protobufData: Data, transitionFrameCount: Int) {
        player?.handleTransitionEnd(protobufData, count: transitionFrameCount)
    }
    func onIdleStart() {
        player?.handleIdleStart()
    }
    func onStreamStats(_ stats: RTCStreamStats) {
        player?.handleStreamStats(stats)
    }
}
