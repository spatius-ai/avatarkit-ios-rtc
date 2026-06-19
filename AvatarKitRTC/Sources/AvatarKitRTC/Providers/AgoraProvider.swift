import Foundation
import AgoraRtcKit
import AvatarKitAgoraBridge

/// Agora RTC provider for iOS.
///
/// 1:1 port of `@spatius/avatarkit-rtc`'s `AgoraProvider.ts`, with the key
/// difference that Agora's iOS SDK doesn't surface a `sei-received` event.
/// We register a C++ `IVideoEncodedFrameObserver` (via the ObjC++ bridge in
/// `AvatarKitAgoraBridge`), then slice NAL units + extract SEI ourselves
/// (`H264SEIExtractor`) and parse our wire format (`SEIPacketParser`).
///
/// Audio is handled entirely by Agora — the SDK auto-subscribes and plays
/// remote audio through its built-in audio session. We never touch PCM here.
@MainActor public final class AgoraProvider: BaseRTCProvider, AgoraRtcEngineDelegate {
    public override var name: String { "agora" }

    private let logger = RTCLogger("AgoraProvider")
    private var engine: AgoraRtcEngineKit?

    /// The native Agora `AgoraRtcEngineKit`, or nil if not connected.
    public override func getNativeClient() -> Any? { engine }
    private var observer: AKAgoraEncodedFrameObserver?
    private let parser = SEIPacketParser()
    private var animationCallbacks: AnimationTrackCallbacks?

    // Diagnostics: count NAL frames + SEI payloads from the observer.
    private var nalFrameCount = 0
    private var seiPayloadCount = 0
    private var lastNalLogAt: TimeInterval = 0

    private var localUid: UInt = 0
    private var hasJoined = false
    private var hasPublishedAudio = false

    // External PCM source state (used for integration tests / programmatic
    // audio injection that doesn't go through the device microphone).
    private var customAudioTrackId: Int = 0
    private var externalSampleRate: Int = 16000
    private var externalChannels: Int = 1

    public override init() {
        super.init()
    }

    // MARK: - RTCProvider

    public override func connect(_ config: RTCConnectionConfig) async throws {
        guard let cfg = config as? AgoraConnectionConfig else {
            throw AgoraProviderError.invalidConfig("Expected AgoraConnectionConfig")
        }
        if engine != nil {
            logger.warn("Engine already created; disconnect first")
            return
        }

        let engineConfig = AgoraRtcEngineConfig()
        engineConfig.appId = cfg.appId
        engineConfig.channelProfile = .liveBroadcasting
        let kit = AgoraRtcEngineKit.sharedEngine(with: engineConfig, delegate: self)

        // Required for SEI delivery on subscribers.
        kit.setParameters("{\"rtc.video.enable_sei\":true}")
        // Default to broadcaster so we can publish mic when requested.
        kit.setClientRole(.broadcaster)
        // Subscribers should ask for encoded video so the observer fires.
        let opts = AgoraRtcChannelMediaOptions()
        opts.autoSubscribeAudio = true
        opts.autoSubscribeVideo = true
        opts.publishCameraTrack = false
        opts.publishMicrophoneTrack = false
        opts.clientRoleType = .broadcaster

        self.engine = kit
        setConnectionState(.connecting)

        // Install the encoded frame observer **before** joining so we don't
        // miss the first frames.
        //
        // Threading model:
        //   1. Agora calls back on its internal `aosl_main` thread, which is
        //      guarded by `dispatch_assert_queue` — non-trivial work there
        //      trips EXC_BREAKPOINT. Hop off immediately.
        //   2. NAL slicing + SEI payload extraction run on a dedicated serial
        //      queue (CPU-bound, no UI work).
        //   3. The MainActor is only touched when there are SEI payloads to
        //      dispatch, or rarely for diagnostics — empty frames never wake
        //      the UI thread.
        let workQueue = DispatchQueue(label: "ai.spatius.rtc.agora-nal", qos: .userInitiated)
        nonisolated(unsafe) var localFrameCount = 0
        let obs = AKAgoraEncodedFrameObserver()
        obs.handler = { [weak self] nalData, uid in
            // `nalData` is bridged from NSData to Swift `Data`, which is a
            // value type backed by COW storage. Passing the bridged Data into
            // a dispatch block is safe (and zero-copy in the common case where
            // we never mutate it).
            workQueue.async { [weak self, nalData] in
                guard let self else { return }
                localFrameCount += 1
                let frames = localFrameCount
                let payloads = H264SEIExtractor.extractUserDataPayloads(from: nalData)
                let shouldDiag = frames <= 3
                let headHex: String
                let diag: String
                if shouldDiag {
                    headHex = nalData.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                    diag = H264SEIExtractor.diagnose(nalData)
                } else {
                    headHex = ""
                    diag = ""
                }
                let bytes = nalData.count
                // Only touch the MainActor when we actually have something for
                // it (avoids scheduling ~25 empty Tasks/sec onto the UI thread).
                let wantDiag = shouldDiag || (frames % 100) == 0
                guard !payloads.isEmpty || wantDiag else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if wantDiag {
                        self.recordNalDiagnostics(uid: uid, frames: frames, nalBytes: bytes, seiCount: payloads.count, headHex: headHex, diag: diag)
                    }
                    for payload in payloads {
                        self.parser.handleSEIPayload(payload)
                    }
                }
            }
        }
        if !obs.attach(toEngine: kit) {
            logger.error("Failed to register encoded frame observer")
        }
        self.observer = obs

        let joinRc = kit.joinChannel(
            byToken: cfg.token,
            channelId: cfg.channel,
            uid: cfg.uid ?? 0,
            mediaOptions: opts
        ) { [weak self] _, uid, _ in
            self?.localUid = UInt(uid)
            self?.hasJoined = true
        }
        if joinRc != 0 {
            setConnectionState(.failed)
            throw AgoraProviderError.joinFailed(Int(joinRc))
        }

        // Wait for either Connected event or 15s timeout.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            joinContinuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                if self.connectionState != .connected, let pending = self.joinContinuation {
                    self.joinContinuation = nil
                    pending.resume(throwing: AgoraProviderError.joinTimeout)
                }
            }
        }
    }

    public override func disconnect() async {
        if let obs = observer {
            obs.detach()
            observer = nil
        }
        parser.detach()
        animationCallbacks = nil
        if let kit = engine, hasJoined {
            kit.leaveChannel(nil)
        }
        if engine != nil {
            AgoraRtcEngineKit.destroy()
        }
        engine = nil
        hasJoined = false
        hasPublishedAudio = false
        setConnectionState(.disconnected)
    }

    public override func subscribeAnimationTrack(_ callbacks: AnimationTrackCallbacks) async {
        animationCallbacks = callbacks
        parser.attach(callbacks)
    }

    public override func unsubscribeAnimationTrack() async {
        parser.detach()
        animationCallbacks = nil
    }

    public override func publishAudioTrack() async throws {
        guard let kit = engine else { throw AgoraProviderError.notConnected }
        kit.enableLocalAudio(true)
        let opts = AgoraRtcChannelMediaOptions()
        opts.publishMicrophoneTrack = true
        kit.updateChannel(with: opts)
        hasPublishedAudio = true
    }

    public override func unpublishAudioTrack() async {
        guard let kit = engine else { return }
        let opts = AgoraRtcChannelMediaOptions()
        opts.publishMicrophoneTrack = false
        if customAudioTrackId != 0 {
            opts.publishCustomAudioTrack = false
            opts.publishCustomAudioTrackId = Int(customAudioTrackId)
        }
        kit.updateChannel(with: opts)
        kit.enableLocalAudio(false)
        if customAudioTrackId != 0 {
            kit.destroyCustomAudioTrack(Int(customAudioTrackId))
            customAudioTrackId = 0
        }
        hasPublishedAudio = false
    }

    // MARK: - External PCM audio source

    public override func publishExternalPCM(sampleRate: Int, channels: Int) async throws {
        guard let kit = engine else { throw AgoraProviderError.notConnected }
        // Don't fight the mic — only one of mic / custom track can publish at a time.
        if hasPublishedAudio {
            await unpublishAudioTrack()
        }

        externalSampleRate = sampleRate
        externalChannels = channels

        let config = AgoraAudioTrackConfig()
        config.enableLocalPlayback = false
        let trackId = kit.createCustomAudioTrack(.mixable, config: config)
        guard trackId > 0 else {
            throw AgoraProviderError.externalAudioStartFailed("createCustomAudioTrack returned \(trackId)")
        }
        customAudioTrackId = Int(trackId)

        let opts = AgoraRtcChannelMediaOptions()
        opts.publishMicrophoneTrack = false
        opts.publishCustomAudioTrack = true
        opts.publishCustomAudioTrackId = customAudioTrackId
        kit.updateChannel(with: opts)

        hasPublishedAudio = true
    }

    public override func pushExternalPCM(_ data: Data) async {
        guard let kit = engine, customAudioTrackId != 0, !data.isEmpty else { return }
        let bytesPerSample = 2 * externalChannels
        let samples = data.count / bytesPerSample
        guard samples > 0 else { return }
        // Agora expects a contiguous buffer that lives for the duration of the
        // call. Make a fresh Data copy and push it inline; the SDK copies into
        // its own queue before returning.
        let buffer = NSData(data: data)
        let timestamp = Date().timeIntervalSince1970
        _ = buffer.bytes.withMemoryRebound(to: Int8.self, capacity: buffer.length) { _ -> Int in
            kit.pushExternalAudioFrameRawData(
                UnsafeMutableRawPointer(mutating: buffer.bytes),
                samples: samples,
                sampleRate: externalSampleRate,
                channels: externalChannels,
                trackId: customAudioTrackId,
                timestamp: timestamp
            )
            return 0
        }
    }

    // MARK: - Diagnostics

    private func recordNalDiagnostics(uid: UInt, frames: Int, nalBytes: Int, seiCount: Int, headHex: String, diag: String) {
        nalFrameCount = frames
        seiPayloadCount += seiCount
        if frames <= 3 {
            logger.info("NAL #\(frames) uid=\(uid) bytes=\(nalBytes) sei=\(seiCount) head=\(headHex) \(diag)")
        }
        let now = Date().timeIntervalSince1970
        if now - lastNalLogAt >= 2.0 {
            lastNalLogAt = now
            logger.info("NAL stats frames=\(frames) sei=\(seiPayloadCount)")
        }
    }

    // MARK: - AgoraRtcEngineDelegate

    private var joinContinuation: CheckedContinuation<Void, Error>?

    nonisolated public func rtcEngine(_ engine: AgoraRtcEngineKit, didJoinChannel channel: String, withUid uid: UInt, elapsed: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.logger.info("Joined channel=\(channel) uid=\(uid) elapsed=\(elapsed)ms")
            self.setConnectionState(.connected)
            self.emit(.connected)
            if let cont = self.joinContinuation {
                self.joinContinuation = nil
                cont.resume()
            }
        }
    }

    nonisolated public func rtcEngine(_ engine: AgoraRtcEngineKit, didLeaveChannelWith stats: AgoraChannelStats) {
        Task { @MainActor [weak self] in
            self?.setConnectionState(.disconnected)
            self?.emit(.disconnected)
        }
    }

    nonisolated public func rtcEngine(_ engine: AgoraRtcEngineKit, didOccurError errorCode: AgoraErrorCode) {
        let msg = "Agora error \(errorCode.rawValue)"
        Task { @MainActor [weak self] in
            self?.logger.error(msg)
            self?.emit(.error(msg))
        }
    }

    nonisolated public func rtcEngine(_ engine: AgoraRtcEngineKit, connectionChangedTo state: AgoraConnectionState, reason: AgoraConnectionChangedReason) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let mapped: RTCConnectionState
            switch state {
            case .disconnected:  mapped = .disconnected
            case .connecting:    mapped = .connecting
            case .connected:     mapped = .connected
            case .reconnecting:  mapped = .reconnecting
            case .failed:        mapped = .failed
            @unknown default:    mapped = .failed
            }
            self.setConnectionState(mapped)
            // `connectionChangedTo(.connected)` can fire before
            // `didJoinChannel` (or instead of it on reconnect). Resume the
            // pending continuation here too — otherwise the awaiting
            // AvatarPlayer.connect() hangs until the 15s timeout, which then
            // refuses to throw because connectionState is already .connected,
            // leaving the continuation dangling forever.
            if mapped == .connected, let cont = self.joinContinuation {
                self.joinContinuation = nil
                cont.resume()
            } else if mapped == .failed, let cont = self.joinContinuation {
                self.joinContinuation = nil
                cont.resume(throwing: AgoraProviderError.joinFailed(-1))
            }
        }
    }
}

public enum AgoraProviderError: LocalizedError {
    case invalidConfig(String)
    case notConnected
    case joinFailed(Int)
    case joinTimeout
    case externalAudioStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfig(let m): return "Invalid config: \(m)"
        case .notConnected: return "Not connected to Agora channel"
        case .joinFailed(let rc): return "Agora joinChannel failed: rc=\(rc)"
        case .joinTimeout: return "Agora joinChannel timed out"
        case .externalAudioStartFailed(let m): return "Failed to start external audio: \(m)"
        }
    }
}
