import Foundation
import AvatarKit
import AvatarKitRTC

/// One integration test case. The `run` closure is invoked on the main actor
/// with a fully wired `TestContext` (player connected, avatar loaded).
struct TestCase {
    let id: String
    let name: String
    let group: String
    let timeoutMs: Int
    let run: @MainActor (TestContext) async throws -> Void
}

enum TestStatus: String {
    case pass = "PASS"
    case fail = "FAIL"
    case skip = "SKIP"
}

struct TestResult {
    let id: String
    let index: Int
    let name: String
    let group: String
    var status: TestStatus = .pass
    var durationMs: Int = 0
    var error: String? = nil
    var logs: [String] = []
}

struct AssertionError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TimeoutError: Error, LocalizedError {
    let milliseconds: Int
    var errorDescription: String? { "Timeout (\(milliseconds)ms)" }
}

/// Connection info returned by the demo backend's `/api/agora-token` endpoint.
struct AgoraConnection: Sendable {
    let appId: String
    let channelName: String
    let token: String
    let uid: UInt
}

/// All test cases run against the same `AvatarPlayer` instance held by the
/// runner. Tests that need to disconnect/reconnect call into the context.
@MainActor
protocol TestContext: AnyObject {
    var player: AvatarPlayer { get }
    var provider: RTCProvider { get }
    var avatarView: AvatarView { get }
    var connection: AgoraConnection { get }

    /// Non-nil when the runner is using `MockRTCProvider`. Mock-only tests
    /// inject packets through this.
    var mock: MockRTCProvider? { get }

    /// Raw 16kHz / 16-bit mono PCM bytes bundled with the demo.
    var pcmData: Data { get }

    /// Animation frames received since last reset. Counted by tapping into the
    /// AnimationTrackCallbacks at runner setup.
    var frameCount: Int { get }
    func resetFrameCount()

    /// Player events captured since last reset.
    var capturedEvents: [AvatarPlayerEvent] { get }
    func resetEvents()

    /// Fetch a fresh token + channel from the demo backend.
    func fetchNewToken() async throws -> AgoraConnection

    /// Wait for at least `minFrames` animation frames or throw on timeout.
    @discardableResult
    func waitForFrames(_ minFrames: Int, timeoutMs: Int) async throws -> Int

    /// Wait for a player event of the given kind. Returns the event payload.
    @discardableResult
    func waitForEvent(_ kind: PlayerEventKind, timeoutMs: Int) async throws -> AvatarPlayerEvent

    /// Sleep `durationMs` (test-friendly wrapper around Task.sleep).
    func wait(_ durationMs: Int) async

    /// Push raw PCM into the channel via Agora's external-audio-frame API.
    /// Returns the playback duration in milliseconds (so callers can sleep).
    func pushPcm() async throws -> Int

    func log(_ msg: String)
    func assert(_ condition: Bool, _ message: String) throws
}

/// Coarse-grained event kind matchers for `waitForEvent`.
enum PlayerEventKind {
    case connected
    case disconnected
    case error
    case stalled
    case connectionStateChanged(RTCConnectionState)

    func matches(_ event: AvatarPlayerEvent) -> Bool {
        switch (self, event) {
        case (.connected, .connected): return true
        case (.disconnected, .disconnected): return true
        case (.error, .error): return true
        case (.stalled, .stalled): return true
        case (.connectionStateChanged(let want), .connectionStateChanged(let got)): return want == got
        default: return false
        }
    }
}
