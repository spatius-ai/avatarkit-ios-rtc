import Foundation

/// Callbacks AvatarKitRTC uses to receive animation data from a provider.
/// Providers extract raw protobuf bytes from their transport (e.g. Agora SEI)
/// and dispatch them through these hooks.
/// Hooks run on the main actor — providers should hop threads before calling.
@MainActor public protocol AnimationTrackCallbacks: AnyObject {
    func onAnimationData(_ protobufData: Data, metadata: AnimationFrameMetadata)
    func onTransition(_ protobufData: Data, transitionFrameCount: Int)
    func onTransitionEnd(_ protobufData: Data, transitionFrameCount: Int)
    func onIdleStart()
    func onSessionStart()
    func onSessionEnd()
    func onStreamStats(_ stats: RTCStreamStats)
}

/// Default empty implementations so concrete callback objects only override
/// what they care about.
@MainActor public extension AnimationTrackCallbacks {
    func onSessionStart() {}
    func onSessionEnd() {}
}

/// Default `notSupported` stubs for providers that don't implement external
/// audio. Tests / advanced consumers that need PCM injection will pick a
/// provider that overrides these (e.g. AgoraProvider).
@MainActor public extension RTCProvider {
    func publishExternalPCM(sampleRate: Int, channels: Int) async throws {
        throw RTCProviderError.externalAudioNotSupported
    }

    func pushExternalPCM(_ data: Data) async {
        // no-op by default
    }
}

public enum RTCProviderError: LocalizedError {
    case externalAudioNotSupported

    public var errorDescription: String? {
        switch self {
        case .externalAudioNotSupported:
            return "This RTC provider does not support external PCM audio."
        }
    }
}

/// Provider events delivered to AvatarPlayer.
public enum RTCProviderEvent: Sendable {
    case connected
    case disconnected
    case error(String)
    case connectionStateChanged(RTCConnectionState)
}

/// Abstract interface every RTC provider must implement. iOS currently
/// ships `AgoraProvider`. Applications normally interact with `AvatarPlayer`
/// rather than this protocol directly.
@MainActor public protocol RTCProvider: AnyObject {
    /// Provider name, used for logs and telemetry.
    var name: String { get }

    /// Connect to the RTC server.
    func connect(_ config: RTCConnectionConfig) async throws

    /// Disconnect from the RTC server. Cleans up tracks and resources.
    func disconnect() async

    /// Current connection state.
    var connectionState: RTCConnectionState { get }

    /// Subscribe to the animation data stream.
    func subscribeAnimationTrack(_ callbacks: AnimationTrackCallbacks) async

    /// Stop receiving animation data.
    func unsubscribeAnimationTrack() async

    /// Publish a local audio source. Pass nil to publish the default microphone.
    func publishAudioTrack() async throws

    /// Stop publishing the local audio source.
    func unpublishAudioTrack() async

    /// Publish an external PCM stream as the local audio source — analogous to
    /// passing a `MediaStreamTrack` to web's `publishAudioTrack(track)`. The
    /// audio bytes are pushed via `pushExternalPCM(_:)` after publish starts.
    ///
    /// Default implementation throws `notSupported`; providers that can route
    /// PCM into their internal audio pipeline (e.g. Agora's external audio
    /// source) override this.
    func publishExternalPCM(sampleRate: Int, channels: Int) async throws

    /// Push a chunk of 16-bit signed little-endian PCM into the previously
    /// started external audio source. No-op if external audio isn't enabled.
    func pushExternalPCM(_ data: Data) async

    /// Listen to provider lifecycle events.
    func setEventHandler(_ handler: @escaping @MainActor (RTCProviderEvent) -> Void)

    /// The underlying native RTC client, or nil if not connected — e.g.
    /// `AgoraProvider` returns its `AgoraRtcEngineKit`. Lets advanced callers
    /// reach provider-specific features not exposed through the unified API.
    /// Aligned with Android / web `getNativeClient()`.
    func getNativeClient() -> Any?
}

/// Common boilerplate shared between provider implementations.
/// Inherits from NSObject so subclasses can adopt Objective-C delegate
/// protocols (e.g. AgoraRtcEngineDelegate) directly.
@MainActor open class BaseRTCProvider: NSObject, RTCProvider {
    open var name: String { "base" }

    public private(set) var connectionState: RTCConnectionState = .disconnected

    private var handler: (@MainActor (RTCProviderEvent) -> Void)?
    private let logger: RTCLogger

    public override init() {
        self.logger = RTCLogger("Provider.base")
        super.init()
    }

    public func setEventHandler(_ handler: @escaping @MainActor (RTCProviderEvent) -> Void) {
        self.handler = handler
    }

    /// Default: no native client exposed. Providers override to return theirs.
    open func getNativeClient() -> Any? { nil }

    open func connect(_ config: RTCConnectionConfig) async throws {
        fatalError("subclass must override connect")
    }

    open func disconnect() async {
        fatalError("subclass must override disconnect")
    }

    open func subscribeAnimationTrack(_ callbacks: AnimationTrackCallbacks) async {
        fatalError("subclass must override subscribeAnimationTrack")
    }

    open func unsubscribeAnimationTrack() async {
        fatalError("subclass must override unsubscribeAnimationTrack")
    }

    open func publishAudioTrack() async throws {
        fatalError("subclass must override publishAudioTrack")
    }

    open func unpublishAudioTrack() async {
        fatalError("subclass must override unpublishAudioTrack")
    }

    open func publishExternalPCM(sampleRate: Int, channels: Int) async throws {
        throw RTCProviderError.externalAudioNotSupported
    }

    open func pushExternalPCM(_ data: Data) async {
        // no-op by default
    }

    /// Subclasses call this to update state and emit a state-change event.
    public func setConnectionState(_ state: RTCConnectionState) {
        guard state != connectionState else { return }
        let prev = connectionState
        connectionState = state
        switch state {
        case .disconnected, .failed:
            logger.error("Connection: \(prev.rawValue) -> \(state.rawValue)")
        case .reconnecting:
            logger.warn("Connection: \(prev.rawValue) -> \(state.rawValue)")
        default:
            logger.info("Connection: \(prev.rawValue) -> \(state.rawValue)")
        }
        emit(.connectionStateChanged(state))
    }

    /// Subclasses call this to surface provider lifecycle events.
    public func emit(_ event: RTCProviderEvent) {
        handler?(event)
    }
}
