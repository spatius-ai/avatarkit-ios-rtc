import Foundation
import AvatarKit
import AvatarKitRTC

/// A pure in-memory `RTCProvider` for testing the AvatarPlayer / AnimationHandler
/// state machine without touching the network.
///
/// The provider never connects to a real server. Test code drives every
/// transition manually via the `inject*` methods, and the SDK's reactions
/// flow back through whatever callbacks AvatarPlayer registers.
///
/// Lifecycle handled by the mock:
/// - `connect` / `disconnect` flip an internal flag and emit the same events
///   the real provider would (connection-state changed + connected/
///   disconnected).
/// - `subscribeAnimationTrack` captures the bridge `AvatarPlayer` passes in,
///   so test code can fire animation events into the SDK at will.
/// - `publishAudioTrack` / `publishExternalPCM` / `pushExternalPCM` are no-ops
///   that just remember "I'm publishing" so unpublishAudio tests can assert.
@MainActor
final class MockRTCProvider: RTCProvider {
    let name = "mock"
    private(set) var connectionState: RTCConnectionState = .disconnected

    private var eventHandler: (@MainActor (RTCProviderEvent) -> Void)?
    private(set) var animationCallbacks: AnimationTrackCallbacks?

    // Recorded side-effects (test assertions inspect these).
    private(set) var connectCalls: [RTCConnectionConfig] = []
    private(set) var disconnectCalls = 0
    private(set) var publishAudioCalls = 0
    private(set) var unpublishAudioCalls = 0
    private(set) var publishExternalCalls: [(sampleRate: Int, channels: Int)] = []
    private(set) var pushedPCMByteCount = 0
    private(set) var subscribeCalls = 0
    private(set) var unsubscribeCalls = 0

    private var isAudioPublished = false

    /// Behavior knobs — tests flip these to simulate errors.
    var connectShouldThrow: Error?
    var publishShouldThrow: Error?

    // MARK: - RTCProvider

    func connect(_ config: RTCConnectionConfig) async throws {
        connectCalls.append(config)
        setConnectionState(.connecting)
        if let err = connectShouldThrow {
            setConnectionState(.failed)
            throw err
        }
        setConnectionState(.connected)
        emit(.connected)
    }

    func disconnect() async {
        disconnectCalls += 1
        animationCallbacks = nil
        isAudioPublished = false
        setConnectionState(.disconnected)
        emit(.disconnected)
    }

    func subscribeAnimationTrack(_ callbacks: AnimationTrackCallbacks) async {
        subscribeCalls += 1
        animationCallbacks = callbacks
    }

    func unsubscribeAnimationTrack() async {
        unsubscribeCalls += 1
        animationCallbacks = nil
    }

    func publishAudioTrack() async throws {
        publishAudioCalls += 1
        if let err = publishShouldThrow { throw err }
        isAudioPublished = true
    }

    func unpublishAudioTrack() async {
        unpublishAudioCalls += 1
        isAudioPublished = false
    }

    func publishExternalPCM(sampleRate: Int, channels: Int) async throws {
        publishExternalCalls.append((sampleRate, channels))
        if let err = publishShouldThrow { throw err }
        isAudioPublished = true
    }

    func pushExternalPCM(_ data: Data) async {
        pushedPCMByteCount += data.count
    }

    func setEventHandler(_ handler: @escaping @MainActor (RTCProviderEvent) -> Void) {
        eventHandler = handler
    }

    // MARK: - Injection API (test-only)

    /// Push an idle marker — the SDK should switch back to idle if it was speaking.
    func injectIdleStart() {
        animationCallbacks?.onIdleStart()
    }

    /// Push a "transition from idle to speaking" packet. The protobuf payload
    /// is opaque to the parser at this layer; we hand it through verbatim so
    /// the renderer will eventually try to decode it.
    func injectTransitionStart(_ protobufData: Data, frameCount: Int = 8) {
        animationCallbacks?.onTransition(protobufData, transitionFrameCount: frameCount)
    }

    /// Push a "transition from speaking back to idle" packet.
    func injectTransitionEnd(_ protobufData: Data, frameCount: Int = 12) {
        animationCallbacks?.onTransitionEnd(protobufData, transitionFrameCount: frameCount)
    }

    /// Push a single animation frame. `frameSeq` lets tests simulate
    /// in-order, out-of-order, missing, or duplicate frames.
    func injectAnimationFrame(
        _ protobufData: Data,
        frameSeq: Int? = nil,
        isStart: Bool = false,
        isEnd: Bool = false,
        isIdle: Bool = false,
        isRecovered: Bool = false
    ) {
        let meta = AnimationFrameMetadata(
            frameSeq: frameSeq,
            isStart: isStart,
            isEnd: isEnd,
            isIdle: isIdle,
            isRecovered: isRecovered
        )
        animationCallbacks?.onAnimationData(protobufData, metadata: meta)
    }

    /// Push a synthetic stream-stats sample (jitter buffer / FPS bookkeeping).
    func injectStreamStats(_ stats: RTCStreamStats) {
        animationCallbacks?.onStreamStats(stats)
    }

    /// Push a provider-level event, e.g. a simulated reconnect or error.
    func injectProviderEvent(_ event: RTCProviderEvent) {
        // Provider events that affect connection state also update our
        // internal mirror so subsequent `connectionState` reads match the
        // SDK's view.
        if case .connectionStateChanged(let state) = event {
            setConnectionState(state)
        }
        emit(event)
    }

    // MARK: - Internal helpers

    private func setConnectionState(_ state: RTCConnectionState) {
        guard state != connectionState else { return }
        connectionState = state
        emit(.connectionStateChanged(state))
    }

    private func emit(_ event: RTCProviderEvent) {
        eventHandler?(event)
    }
}
