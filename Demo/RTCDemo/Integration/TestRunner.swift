import Foundation
import UIKit
import AvatarKit
import AvatarKitRTC

typealias OnProgress = (Int, Int, String) -> Void
typealias OnResult = (TestResult) -> Void

/// Runs integration test cases sequentially against a real Agora channel.
/// One `AvatarPlayer` is created up front and shared by every case; cases
/// that need to disconnect manage it themselves and the runner reconnects
/// before the next one.
enum RunnerMode {
    /// Talks to the real Agora backend via the public demo API. Slow,
    /// non-deterministic, sensitive to network — keep this for smoke
    /// coverage only.
    case live
    /// Uses `MockRTCProvider`. All packet flow is injected by the test code.
    /// No network. Used for state-machine / boundary-condition coverage.
    case mock
}

@MainActor
final class TestRunner {
    private var aborted = false
    private var results: [TestResult] = []

    private let cases: [TestCase]
    private let mode: RunnerMode
    private let onProgress: OnProgress?
    private let onResult: OnResult?

    init(mode: RunnerMode,
         cases: [TestCase],
         onProgress: OnProgress? = nil,
         onResult: OnResult? = nil) {
        self.mode = mode
        self.cases = cases
        self.onProgress = onProgress
        self.onResult = onResult
    }

    func abort() { aborted = true }

    func run(
        container: UIView,
        baseURL: String,
        appId: String,
        avatarId: String,
        pcmData: Data
    ) async -> [TestResult] {
        aborted = false
        results = []

        // ---- One-time setup: load avatar, fetch first token, connect ----
        AvatarSDK.initialize(
            appID: appId,
            configuration: Configuration(
                audioFormat: AudioFormat(sampleRate: 16000),
                drivingServiceMode: .direct,
                logLevel: .warning
            )
        )

        let avatar: Avatar
        do {
            if let cached = AvatarManager.shared.retrieve(id: avatarId) {
                avatar = cached
            } else {
                avatar = try await AvatarManager.shared.load(id: avatarId)
            }
        } catch {
            // Bail out with one synthetic failure if avatar load fails.
            let r = TestResult(id: "setup", index: 1, name: "Avatar load",
                               group: "Setup", status: .fail,
                               error: "Avatar load failed: \(error.localizedDescription)")
            results.append(r)
            onResult?(r)
            return results
        }

        container.subviews.forEach { $0.removeFromSuperview() }
        let avatarView = AvatarView(avatar: avatar)
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.backgroundColor = .black
        container.addSubview(avatarView)
        NSLayoutConstraint.activate([
            avatarView.topAnchor.constraint(equalTo: container.topAnchor),
            avatarView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            avatarView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            avatarView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let backend = DemoBackend(baseURL: baseURL)

        let provider: RTCProvider
        let mockProvider: MockRTCProvider?
        var firstConn = AgoraConnection(appId: "mock", channelName: "mock", token: "", uid: 0)

        switch mode {
        case .live:
            do {
                firstConn = try await backend.fetchToken(avatarId: avatarId)
            } catch {
                let r = TestResult(id: "setup", index: 1, name: "Initial token fetch",
                                   group: "Setup", status: .fail,
                                   error: "Token fetch failed: \(error.localizedDescription)")
                results.append(r)
                onResult?(r)
                return results
            }
            provider = HookableProvider()
            mockProvider = nil
        case .mock:
            let m = MockRTCProvider()
            provider = m
            mockProvider = m
        }

        let player = AvatarPlayer(
            provider: provider,
            avatarView: avatarView,
            options: AvatarPlayerOptions(logLevel: .warning)
        )

        let ctx = TestContextImpl(
            player: player,
            provider: provider,
            avatarView: avatarView,
            connection: firstConn,
            pcmData: pcmData,
            backend: backend,
            avatarId: avatarId,
            mock: mockProvider
        )

        // Capture player events at the AvatarPlayer level (subscribe). This is
        // the public hook we have without modifying the SDK.
        player.subscribe { [weak ctx] event in ctx?.recordEvent(event) }

        // Connect once before tests start; tests that disconnect must reconnect.
        do {
            switch mode {
            case .live:
                try await player.connect(AgoraConnectionConfig(
                    appId: firstConn.appId,
                    channel: firstConn.channelName,
                    token: firstConn.token,
                    uid: firstConn.uid
                ))
                // Give the egress side ~5s to join + start streaming animation frames.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            case .mock:
                try await player.connect(MockConnectionConfig())
            }
        } catch {
            let r = TestResult(id: "setup", index: 1, name: "Initial connect",
                               group: "Setup", status: .fail,
                               error: "Connect failed: \(error.localizedDescription)")
            results.append(r)
            onResult?(r)
            await player.disconnect()
            return results
        }

        // ---- Run cases ----
        let total = cases.count
        for i in 0..<total {
            if aborted { break }

            if i > 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }

            let tc = cases[i]
            onProgress?(i + 1, total, tc.name)

            ctx.beginCase()

            var result = TestResult(
                id: tc.id, index: i + 1, name: tc.name, group: tc.group
            )
            let start = ContinuousClock.now

            do {
                try await withTimeout(ms: tc.timeoutMs) {
                    try await tc.run(ctx)
                }
            } catch let e as TimeoutError {
                result.status = .fail
                result.error = e.errorDescription
            } catch let e as AssertionError {
                result.status = .fail
                result.error = e.message
            } catch {
                result.status = .fail
                result.error = error.localizedDescription
            }

            let elapsed = ContinuousClock.now - start
            result.durationMs = Int(elapsed / .milliseconds(1))
            result.logs = ctx.flushLogs()
            results.append(result)
            onResult?(result)

            // If the case left us disconnected, try to reconnect so the next
            // case starts from a clean state.
            if !player.isConnected, i + 1 < total {
                do {
                    try await player.reconnect()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    // Subsequent cases will likely fail; let them report it.
                }
            }
        }

        await player.disconnect()
        return results
    }

    // MARK: - Timeout wrapper

    /// Runs `work` with a wall-clock deadline. Whichever finishes first wins;
    /// the loser is cancelled. Implemented with a continuation so it stays
    /// region-isolation friendly on Swift 6.
    private func withTimeout(
        ms: Int,
        _ work: @escaping @MainActor () async throws -> Void
    ) async throws {
        final class State: @unchecked Sendable {
            var resumed = false
            var bodyTask: Task<Void, Error>?
            var timeoutTask: Task<Void, Never>?
        }
        let state = State()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            state.bodyTask = Task { @MainActor in
                do {
                    try await work()
                    if !state.resumed {
                        state.resumed = true
                        state.timeoutTask?.cancel()
                        cont.resume()
                    }
                } catch {
                    if !state.resumed {
                        state.resumed = true
                        state.timeoutTask?.cancel()
                        cont.resume(throwing: error)
                    }
                }
            }
            state.timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
                if !state.resumed {
                    state.resumed = true
                    state.bodyTask?.cancel()
                    cont.resume(throwing: TimeoutError(milliseconds: ms))
                }
            }
        }
    }

    // MARK: - Reports

    static func generateReport(results: [TestResult]) -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        let device = UIDevice.current.name
        let osVersion = UIDevice.current.systemVersion

        let passed = results.filter { $0.status == .pass }.count
        let failed = results.filter { $0.status == .fail }.count
        let skipped = results.filter { $0.status == .skip }.count
        let total = results.count

        var report = ""
        report += "AvatarKitRTC iOS Integration Test Report\n"
        report += "Date: \(now)\n"
        report += "Device: \(device)\n"
        report += "OS: iOS \(osVersion)\n"
        report += "\n"

        var currentGroup = ""
        for r in results {
            if r.group != currentGroup {
                currentGroup = r.group
                report += "--- \(currentGroup) ---\n"
            }
            let tag = "[\(r.status.rawValue)]"
            let time = String(format: "(%.1fs)", Double(r.durationMs) / 1000.0)
            report += "\(tag) \(r.index). \(r.name) \(time)\n"
            if let error = r.error {
                report += "  \(error)\n"
            }
            if r.status == .fail && !r.logs.isEmpty {
                report += "  logs: \(r.logs.joined(separator: " | "))\n"
            }
        }

        report += "\n"
        report += "Result: \(passed)/\(total) passed"
        if failed > 0 { report += ", \(failed) failed" }
        if skipped > 0 { report += ", \(skipped) skipped" }
        report += "\n"
        if failed > 0 {
            let failedNames = results.filter { $0.status == .fail }.map { "#\($0.index)" }
            report += "Failed: \(failedNames.joined(separator: ", "))\n"
        }
        return report
    }
}

// MARK: - Backend client

@MainActor
final class DemoBackend {
    private let baseURL: String
    init(baseURL: String) { self.baseURL = baseURL }

    func fetchToken(avatarId: String) async throws -> AgoraConnection {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/api/agora-token") else {
            throw NSError(domain: "DemoBackend", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "participantName": "ios-integration",
            "avatarId": avatarId,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "DemoBackend", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(msg)"])
        }
        let resp = try JSONDecoder().decode(TokenResponse.self, from: data)
        return AgoraConnection(appId: resp.appId,
                               channelName: resp.channelName,
                               token: resp.token,
                               uid: resp.uid)
    }

    private struct TokenResponse: Decodable {
        let appId: String
        let channelName: String
        let token: String
        let uid: UInt
    }
}

// MARK: - HookableProvider

/// Decorator around the real `AgoraProvider` so the test runner can intercept
/// the `AnimationTrackCallbacks` registered by `AvatarPlayer`. Forwards every
/// RTCProvider method to the underlying provider, and on subscribe replaces
/// the callbacks with a wrapper that bumps a per-frame counter the tests
/// read via `TestContext.frameCount`.
@MainActor
final class HookableProvider: RTCProvider {
    private let underlying = AgoraProvider()
    private(set) var animationFrameCount = 0
    var onAnimationFrame: (() -> Void)?

    var name: String { "agora-hooked" }
    var connectionState: RTCConnectionState { underlying.connectionState }

    func connect(_ config: RTCConnectionConfig) async throws {
        try await underlying.connect(config)
    }
    func disconnect() async { await underlying.disconnect() }

    func subscribeAnimationTrack(_ callbacks: AnimationTrackCallbacks) async {
        let wrapped = HookCallbacks(inner: callbacks, owner: self)
        await underlying.subscribeAnimationTrack(wrapped)
    }
    func unsubscribeAnimationTrack() async { await underlying.unsubscribeAnimationTrack() }

    func publishAudioTrack() async throws { try await underlying.publishAudioTrack() }
    func unpublishAudioTrack() async { await underlying.unpublishAudioTrack() }

    func publishExternalPCM(sampleRate: Int, channels: Int) async throws {
        try await underlying.publishExternalPCM(sampleRate: sampleRate, channels: channels)
    }
    func pushExternalPCM(_ data: Data) async {
        await underlying.pushExternalPCM(data)
    }

    func setEventHandler(_ handler: @escaping @MainActor (RTCProviderEvent) -> Void) {
        underlying.setEventHandler(handler)
    }

    fileprivate func tickAnimationFrame() {
        animationFrameCount += 1
        onAnimationFrame?()
    }

    func resetAnimationFrameCount() { animationFrameCount = 0 }
}

@MainActor
private final class HookCallbacks: AnimationTrackCallbacks {
    private let inner: AnimationTrackCallbacks
    private weak var owner: HookableProvider?

    init(inner: AnimationTrackCallbacks, owner: HookableProvider) {
        self.inner = inner
        self.owner = owner
    }

    func onAnimationData(_ protobufData: Data, metadata: AnimationFrameMetadata) {
        owner?.tickAnimationFrame()
        inner.onAnimationData(protobufData, metadata: metadata)
    }
    func onTransition(_ protobufData: Data, transitionFrameCount: Int) {
        inner.onTransition(protobufData, transitionFrameCount: transitionFrameCount)
    }
    func onTransitionEnd(_ protobufData: Data, transitionFrameCount: Int) {
        inner.onTransitionEnd(protobufData, transitionFrameCount: transitionFrameCount)
    }
    func onIdleStart() { inner.onIdleStart() }
    func onSessionStart() { inner.onSessionStart() }
    func onSessionEnd() { inner.onSessionEnd() }
    func onStreamStats(_ stats: RTCStreamStats) { inner.onStreamStats(stats) }
}

// MARK: - TestContextImpl

@MainActor
final class TestContextImpl: TestContext {
    let player: AvatarPlayer
    let provider: RTCProvider
    let avatarView: AvatarView
    var connection: AgoraConnection
    let pcmData: Data
    let mock: MockRTCProvider?

    private let backend: DemoBackend
    private let avatarId: String
    private var hookedProvider: HookableProvider? { provider as? HookableProvider }

    // Captured events / logs scoped to the current case.
    private var events: [AvatarPlayerEvent] = []
    private var logs: [String] = []

    // One-shot waiters that observers fire.
    private var frameWaiters: [FrameWaiter] = []
    private var eventWaiters: [EventWaiter] = []

    // Frame counter — for live mode uses the hook; for mock mode counts
    // injectAnimationFrame calls separately so tests can still call frameCount.
    private var mockFrameCount = 0

    init(player: AvatarPlayer,
         provider: RTCProvider,
         avatarView: AvatarView,
         connection: AgoraConnection,
         pcmData: Data,
         backend: DemoBackend,
         avatarId: String,
         mock: MockRTCProvider?) {
        self.player = player
        self.provider = provider
        self.avatarView = avatarView
        self.connection = connection
        self.pcmData = pcmData
        self.backend = backend
        self.avatarId = avatarId
        self.mock = mock
        self.hookedProvider?.onAnimationFrame = { [weak self] in
            self?.handleAnimationFrame()
        }
    }

    var frameCount: Int {
        hookedProvider?.animationFrameCount ?? mockFrameCount
    }
    func resetFrameCount() {
        hookedProvider?.resetAnimationFrameCount()
        mockFrameCount = 0
    }

    var capturedEvents: [AvatarPlayerEvent] { events }
    func resetEvents() { events.removeAll() }

    func beginCase() {
        events.removeAll()
        logs.removeAll()
        resetFrameCount()
        frameWaiters.removeAll()
        eventWaiters.removeAll()
    }

    func flushLogs() -> [String] {
        let out = logs
        logs.removeAll()
        return out
    }

    func recordEvent(_ event: AvatarPlayerEvent) {
        events.append(event)
        logs.append("event: \(eventDescription(event))")
        for waiter in eventWaiters {
            if waiter.kind.matches(event) {
                waiter.resume(event)
            }
        }
        eventWaiters.removeAll { $0.resumed }
    }

    private func handleAnimationFrame() {
        let count = frameCount
        for waiter in frameWaiters where !waiter.resumed && count >= waiter.target {
            waiter.resume(count)
        }
        frameWaiters.removeAll { $0.resumed }
    }

    func fetchNewToken() async throws -> AgoraConnection {
        let fresh = try await backend.fetchToken(avatarId: avatarId)
        connection = fresh
        return fresh
    }

    func waitForFrames(_ minFrames: Int, timeoutMs: Int = 15000) async throws -> Int {
        if frameCount >= minFrames { return frameCount }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let waiter = FrameWaiter(target: minFrames, continuation: cont)
            frameWaiters.append(waiter)
            scheduleTimeout(ms: timeoutMs) { [weak self, weak waiter] in
                guard let waiter, !waiter.resumed else { return }
                waiter.fail(TimeoutError(milliseconds: timeoutMs))
                self?.frameWaiters.removeAll { $0 === waiter }
            }
        }
    }

    @discardableResult
    func waitForEvent(_ kind: PlayerEventKind, timeoutMs: Int = 10000) async throws -> AvatarPlayerEvent {
        if let already = events.first(where: { kind.matches($0) }) {
            return already
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AvatarPlayerEvent, Error>) in
            let waiter = EventWaiter(kind: kind, continuation: cont)
            eventWaiters.append(waiter)
            scheduleTimeout(ms: timeoutMs) { [weak self, weak waiter] in
                guard let waiter, !waiter.resumed else { return }
                waiter.fail(TimeoutError(milliseconds: timeoutMs))
                self?.eventWaiters.removeAll { $0 === waiter }
            }
        }
    }

    func wait(_ durationMs: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
    }

    func pushPcm() async throws -> Int {
        // Push bundled PCM through Agora's external audio source — no device
        // microphone involved. Mirrors web's `player.publishAudio(track)` flow
        // where the test feeds an AudioBuffer-derived MediaStreamTrack.
        //
        // PCM is 16-bit signed LE mono @ 16kHz. We chunk into 40ms frames
        // (640 samples * 2 bytes = 1280 bytes) and pace by real time so the
        // egress side sees the same stream a live mic would produce.
        try await player.publishExternalPCM(sampleRate: 16000, channels: 1)
        let chunkBytes = 1280   // 40 ms @ 16kHz mono 16-bit
        let chunkMs = 40
        var offset = 0
        while offset < pcmData.count {
            let end = min(offset + chunkBytes, pcmData.count)
            let chunk = pcmData.subdata(in: offset..<end)
            await player.pushPCM(chunk)
            offset = end
            try? await Task.sleep(nanoseconds: UInt64(chunkMs) * 1_000_000)
        }
        let durationMs = Int((Double(pcmData.count) / 32000.0) * 1000.0)
        await player.unpublishAudio()
        return durationMs
    }

    func log(_ msg: String) { logs.append(msg) }

    func assert(_ condition: Bool, _ message: String) throws {
        if !condition { throw AssertionError(message: message) }
    }

    private func scheduleTimeout(ms: Int, _ block: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            block()
        }
    }

    private func eventDescription(_ e: AvatarPlayerEvent) -> String {
        switch e {
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .error(let m): return "error(\(m))"
        case .stalled: return "stalled"
        case .connectionStateChanged(let s): return "connState(\(s.rawValue))"
        }
    }
}

// MARK: - Waiter primitives

@MainActor
private final class FrameWaiter {
    let target: Int
    let continuation: CheckedContinuation<Int, Error>
    var resumed = false

    init(target: Int, continuation: CheckedContinuation<Int, Error>) {
        self.target = target
        self.continuation = continuation
    }

    func resume(_ count: Int) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: count)
    }

    func fail(_ error: Error) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}

@MainActor
private final class EventWaiter {
    let kind: PlayerEventKind
    let continuation: CheckedContinuation<AvatarPlayerEvent, Error>
    var resumed = false

    init(kind: PlayerEventKind, continuation: CheckedContinuation<AvatarPlayerEvent, Error>) {
        self.kind = kind
        self.continuation = continuation
    }

    func resume(_ event: AvatarPlayerEvent) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: event)
    }

    func fail(_ error: Error) {
        guard !resumed else { return }
        resumed = true
        continuation.resume(throwing: error)
    }
}
