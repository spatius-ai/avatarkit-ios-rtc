import Foundation

/// Connection state for RTC providers.
public enum RTCConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed
}

/// Stream statistics for monitoring and debugging.
public struct RTCStreamStats: Sendable {
    public var framesPerSec: Double
    public var totalFrames: Int
    public var framesSent: Int
    public var framesLost: Int
    public var framesRecovered: Int
    public var framesDropped: Int
    public var framesOutOfOrder: Int
    public var framesDuplicate: Int
    public var lastRenderedSeq: Int

    public init(
        framesPerSec: Double = 0,
        totalFrames: Int = 0,
        framesSent: Int = 0,
        framesLost: Int = 0,
        framesRecovered: Int = 0,
        framesDropped: Int = 0,
        framesOutOfOrder: Int = 0,
        framesDuplicate: Int = 0,
        lastRenderedSeq: Int = -1
    ) {
        self.framesPerSec = framesPerSec
        self.totalFrames = totalFrames
        self.framesSent = framesSent
        self.framesLost = framesLost
        self.framesRecovered = framesRecovered
        self.framesDropped = framesDropped
        self.framesOutOfOrder = framesOutOfOrder
        self.framesDuplicate = framesDuplicate
        self.lastRenderedSeq = lastRenderedSeq
    }
}

/// Per-frame metadata coming from the wire.
public struct AnimationFrameMetadata: Sendable {
    public var frameSeq: Int?
    public var isStart: Bool
    public var isEnd: Bool
    public var isIdle: Bool
    public var isRecovered: Bool

    public init(
        frameSeq: Int? = nil,
        isStart: Bool = false,
        isEnd: Bool = false,
        isIdle: Bool = false,
        isRecovered: Bool = false
    ) {
        self.frameSeq = frameSeq
        self.isStart = isStart
        self.isEnd = isEnd
        self.isIdle = isIdle
        self.isRecovered = isRecovered
    }
}

/// RTC connection configuration. Provider-specific config conforms to this.
public protocol RTCConnectionConfig: Sendable {}

/// Agora connection configuration.
public struct AgoraConnectionConfig: RTCConnectionConfig {
    public let appId: String
    public let channel: String
    public let token: String?
    public let uid: UInt?

    public init(appId: String, channel: String, token: String? = nil, uid: UInt? = nil) {
        self.appId = appId
        self.channel = channel
        self.token = token
        self.uid = uid
    }
}
