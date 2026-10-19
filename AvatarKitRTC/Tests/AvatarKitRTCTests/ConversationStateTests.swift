import XCTest
import AvatarKit
@testable import AvatarKitRTC

/// Render-level conversation state reported by `AnimationHandler` through
/// `AnimationHandlerConfig.onConversationStateChanged`.
///
/// The handler is driven directly against a fake renderer: transitions ride
/// the real playback clock (40 ms slots), so the cases that need a transition
/// to run out wait a few slots of wall time.
@MainActor
final class ConversationStateTests: XCTestCase {

    /// Records renderer calls and hands back synthetic transition frames.
    private final class FakeRenderer: AvatarRendererAdapter {
        var protobufRenders = 0
        var frameRenders = 0
        var idleStarts = 0

        func renderFromProtobuf(_ data: Data) { protobufRenders += 1 }
        func renderFrame(_ frame: Frame?, startIdle: Bool) {
            frameRenders += 1
            if startIdle { idleStarts += 1 }
        }
        func generateTransitionToFrame(_ data: Data, frameCount: Int) -> [Frame] {
            Self.frames(frameCount)
        }
        func generateTransitionToIdle(frameCount: Int) -> [Frame] {
            Self.frames(frameCount)
        }
        func isReady() -> Bool { true }

        private static func frames(_ count: Int) -> [Frame] {
            (0..<count).map { _ in
                Frame(
                    translation: .zero, rotation: [], expression: [],
                    neckPose: [], jawPose: [], eyesPose: [], eyelid: nil
                )
            }
        }
    }

    private var renderer: FakeRenderer!
    private var handler: AnimationHandler!
    private var states: [RTCConversationState] = []

    private func makeHandler(jitterBuffer: Bool) {
        renderer = FakeRenderer()
        var config = AnimationHandlerConfig()
        config.enableJitterBuffer = jitterBuffer
        config.onConversationStateChanged = { [weak self] state in
            self?.states.append(state)
        }
        handler = AnimationHandler(renderer: renderer, config: config)
        states = []
    }

    override func tearDown() async throws {
        handler?.dispose()
        handler = nil
        renderer = nil
    }

    private func settle(ms: UInt64) async throws {
        try await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    private let payload = Data([0x01, 0x02, 0x03])

    // MARK: - speaking

    func testStartTransitionEmitsSpeakingExactlyOnce() async throws {
        makeHandler(jitterBuffer: true)

        handler.handleTransitionData(payload, frameCount: 2)

        // The first transition frame renders synchronously on the first slot.
        XCTAssertEqual(states, [.speaking])
        XCTAssertEqual(renderer.frameRenders, 1)

        // Let the remaining transition frames play out; no repeat.
        try await settle(ms: 200)
        XCTAssertEqual(states, [.speaking])
        XCTAssertGreaterThan(renderer.frameRenders, 1)
    }

    func testBufferedStreamFramesAfterTransitionDoNotRepeatSpeaking() async throws {
        makeHandler(jitterBuffer: true)
        handler.handleTransitionData(payload, frameCount: 2)
        XCTAssertEqual(states, [.speaking])

        for seq in 0..<6 {
            handler.handleAnimationData(payload, frameSeq: seq, isRecovered: false)
        }
        try await settle(ms: 400)

        XCTAssertGreaterThan(renderer.protobufRenders, 0, "stream frames should have drained")
        XCTAssertEqual(states, [.speaking])
    }

    func testDirectStreamFrameWithoutTransitionEmitsSpeakingOnce() {
        // Jitter buffer off: the direct render path in handleAnimationData.
        // This is the "transition packet lost" case.
        makeHandler(jitterBuffer: false)

        for seq in 0..<3 {
            handler.handleAnimationData(payload, frameSeq: seq, isRecovered: false)
        }

        XCTAssertEqual(renderer.protobufRenders, 3)
        XCTAssertEqual(states, [.speaking])
    }

    // MARK: - idle

    func testEndTransitionCompletionEmitsIdleExactlyOnce() async throws {
        makeHandler(jitterBuffer: false)
        handler.handleAnimationData(payload, frameSeq: 0, isRecovered: false)
        XCTAssertEqual(states, [.speaking])

        handler.handleTransitionToIdle(payload, frameCount: 2)
        // Two transition frames on the clock, then the completion slot.
        try await settle(ms: 300)

        XCTAssertEqual(states, [.speaking, .idle])
        XCTAssertEqual(renderer.idleStarts, 1, "idle loop handed back exactly once")

        // Trailing idle packet after the transition: already idle, nothing more.
        handler.startIdle()
        XCTAssertEqual(states, [.speaking, .idle])
        XCTAssertEqual(renderer.idleStarts, 1)
    }

    func testStartIdleWhenAlreadyIdleEmitsNothing() {
        makeHandler(jitterBuffer: false)

        handler.startIdle()
        handler.startIdle()

        XCTAssertEqual(states, [])
        XCTAssertEqual(renderer.idleStarts, 0)
    }

    func testStartIdleWhileSpeakingEmitsIdleOnce() {
        makeHandler(jitterBuffer: false)
        handler.handleAnimationData(payload, frameSeq: 0, isRecovered: false)
        XCTAssertEqual(states, [.speaking])

        handler.startIdle()
        handler.startIdle()

        XCTAssertEqual(states, [.speaking, .idle])
        XCTAssertEqual(renderer.idleStarts, 1)
    }

    func testDisposeWhileSpeakingIsSilentAndNextRoundEdgesAgain() {
        makeHandler(jitterBuffer: false)
        handler.handleAnimationData(payload, frameSeq: 0, isRecovered: false)
        XCTAssertEqual(states, [.speaking])

        // Host teardown: disconnect()/detach() dispose the handler before the
        // player plays its own transition to idle, so the handler itself must
        // stay silent here.
        handler.dispose()
        XCTAssertEqual(states, [.speaking])

        // A reconnect reuses the same handler; the next round's first frame
        // must produce a fresh edge rather than being deduped away.
        handler.resetTracking()
        handler.handleAnimationData(payload, frameSeq: 0, isRecovered: false)
        XCTAssertEqual(states, [.speaking, .speaking])
    }

    func testNoEventAtConstruction() {
        makeHandler(jitterBuffer: true)
        XCTAssertEqual(states, [])
    }

    func testRoundTripSpeakingIdleSpeaking() async throws {
        makeHandler(jitterBuffer: false)
        handler.handleAnimationData(payload, frameSeq: 0, isRecovered: false)
        handler.startIdle()
        handler.resetTracking()
        handler.handleAnimationData(payload, frameSeq: 0, isRecovered: false)

        XCTAssertEqual(states, [.speaking, .idle, .speaking])
    }
}
