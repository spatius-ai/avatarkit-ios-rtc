import Foundation
import Compression

/// Parses our wire-format SEI payload (post-NAL, post-EBSP-strip) into typed
/// animation events and dispatches them through `AnimationTrackCallbacks`.
///
/// Wire format (must match egress server `animation_track.go` and the web
/// `SEIExtractor` constants):
/// ```
/// [1B flags][4B msgLen (LE)][payload of length msgLen]
/// ```
/// Packet flags:
/// - 0x01 Idle (no payload)
/// - 0x02 Start (first frame of a session)
/// - 0x04 End   (last frame)
/// - 0x08 Gzipped (payload is zlib `deflate`)
/// - 0x10 Transition     (idle -> animation)
/// - 0x20 TransitionEnd  (animation -> idle)
///
/// For normal animation frames the decompressed payload is
/// `[4B frameSeq][protobuf bytes]`. Transition frames have no frameSeq prefix.
@MainActor final class SEIPacketParser {
    private struct Flag {
        static let idle: UInt8 = 0x01
        static let start: UInt8 = 0x02
        static let end: UInt8 = 0x04
        static let gzipped: UInt8 = 0x08
        static let transition: UInt8 = 0x10
        static let transitionEnd: UInt8 = 0x20
    }

    private static let headerSize = 5
    private static let frameSeqSize = 4
    private static let defaultTransitionStartFrames = 8
    private static let defaultTransitionEndFrames = 12

    private weak var callbacks: AnimationTrackCallbacks?

    // Session tracking
    private var lastWasIdle = true
    private var isInStartTransition = false
    private var isInEndTransition = false

    // Diagnostics
    private var didLogFirstPayload = false
    private var didLogFirstAnimationFrame = false
    private var didLogFirstTransition = false
    private var didLogFirstIdle = false
    private var inflateFailCount = 0

    // Stream stats
    private var totalFrameCount = 0
    private var intervalFrameCount = 0
    private var lastStatsTime: TimeInterval = 0
    private var statsTask: Task<Void, Never>?

    private let logger = RTCLogger("SEIPacketParser")

    init() {}

    func attach(_ callbacks: AnimationTrackCallbacks) {
        self.callbacks = callbacks
        lastStatsTime = Date().timeIntervalSince1970
        startStatsTimer()
    }

    func detach() {
        statsTask?.cancel()
        statsTask = nil
        callbacks = nil
        lastWasIdle = true
        isInStartTransition = false
        isInEndTransition = false
    }

    /// Feed a raw SEI user_data payload (already past NAL header + payloadType
    /// + payloadSize, EBSP-stripped). Multiple payloads from the same frame
    /// can be fed back-to-back.
    func handleSEIPayload(_ payload: Data) {
        guard let callbacks else { return }
        totalFrameCount += 1
        intervalFrameCount += 1

        guard payload.count >= Self.headerSize else {
            logger.warn("SEI payload too short: \(payload.count)")
            return
        }

        let flags = payload[payload.startIndex]
        let msgLen = readUInt32LE(payload, offset: 1)

        if !didLogFirstPayload {
            didLogFirstPayload = true
            let preview = payload.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            logger.info("First SEI payload bytes=\(payload.count) flags=0x\(String(format: "%02x", flags)) msgLen=\(msgLen) head=\(preview)")
        }

        let isIdle = (flags & Flag.idle) != 0
        if isIdle || msgLen == 0 {
            if !didLogFirstIdle {
                didLogFirstIdle = true
                logger.info("First idle packet flags=0x\(String(format: "%02x", flags)) msgLen=\(msgLen)")
            }
            if !lastWasIdle {
                lastWasIdle = true
                isInStartTransition = false
                isInEndTransition = false
                callbacks.onIdleStart()
            }
            return
        }

        // Take all bytes after the 5-byte header. Server may zero-pad, but msgLen
        // is the authoritative length of the (possibly compressed) payload.
        let payloadStart = payload.startIndex + Self.headerSize
        let rawSlice = Data(payload[payloadStart..<payload.endIndex])
        // Server escapes zero/FF bytes to avoid H.264 emulation-prevention
        // interactions: 00 FF -> 00, FF FF -> FF. Reverse before decompress.
        // Must match web SEIExtractor.unescapeZeroBytes().
        let raw = unescapeZeroBytes(rawSlice)

        let body: Data
        if (flags & Flag.gzipped) != 0 {
            guard let decompressed = inflateZlib(raw) else {
                inflateFailCount += 1
                if inflateFailCount <= 3 || inflateFailCount % 30 == 0 {
                    let head = raw.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                    logger.error("Zlib inflate failed #\(inflateFailCount) (payload=\(raw.count) bytes, head=\(head))")
                }
                return
            }
            body = decompressed
        } else {
            body = raw
        }

        let isTransition = (flags & Flag.transition) != 0
        let isTransitionEnd = (flags & Flag.transitionEnd) != 0
        let isStart = (flags & Flag.start) != 0
        let isEnd = (flags & Flag.end) != 0

        // Transition packets carry the target frame directly (no frameSeq prefix).
        var frameSeq: Int? = nil
        let protobufData: Data
        if isTransition || isTransitionEnd {
            protobufData = body
        } else {
            guard body.count >= Self.frameSeqSize else {
                logger.warn("Animation payload too short for frame sequence: \(body.count)")
                return
            }
            frameSeq = Int(readUInt32LE(body, offset: 0))
            protobufData = Data(body[(body.startIndex + Self.frameSeqSize)...])
        }

        // Dispatch — keep state-machine semantics identical to web SEIExtractor.

        if isTransition {
            if !didLogFirstTransition {
                didLogFirstTransition = true
                logger.info("First transition frame body=\(body.count) protobuf=\(protobufData.count)")
            }
            if !isInStartTransition {
                isInStartTransition = true
                isInEndTransition = false
                callbacks.onTransition(protobufData, transitionFrameCount: Self.defaultTransitionStartFrames)
            }
            return
        }

        if isTransitionEnd {
            if !isInEndTransition {
                isInEndTransition = true
                isInStartTransition = false
                callbacks.onTransitionEnd(protobufData, transitionFrameCount: Self.defaultTransitionEndFrames)
            }
            return
        }

        // Normal animation frame
        isInStartTransition = false
        isInEndTransition = false

        let isFirstFrame = lastWasIdle || isStart
        lastWasIdle = false
        if isFirstFrame {
            callbacks.onSessionStart()
        }

        let meta = AnimationFrameMetadata(
            frameSeq: frameSeq,
            isStart: isFirstFrame,
            isEnd: isEnd,
            isIdle: false,
            isRecovered: false  // Agora handles reliability internally
        )
        if !didLogFirstAnimationFrame {
            didLogFirstAnimationFrame = true
            logger.info("First animation frame seq=\(frameSeq.map(String.init) ?? "nil") body=\(body.count) protobuf=\(protobufData.count)")
        }
        callbacks.onAnimationData(protobufData, metadata: meta)

        if isEnd {
            callbacks.onSessionEnd()
        }
    }

    // MARK: - Stats

    private func startStatsTimer() {
        guard statsTask == nil else { return }
        statsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.reportStats()
            }
        }
    }

    private func reportStats() {
        guard let callbacks else { return }
        let now = Date().timeIntervalSince1970
        let elapsed = now - lastStatsTime
        guard elapsed > 0 else { return }
        let fps = Double(intervalFrameCount) / elapsed
        let stats = RTCStreamStats(
            framesPerSec: (fps * 10).rounded() / 10,
            totalFrames: totalFrameCount,
            framesSent: totalFrameCount,
            framesLost: 0,
            framesRecovered: 0,
            framesDropped: 0,
            framesOutOfOrder: 0,
            framesDuplicate: 0,
            lastRenderedSeq: -1
        )
        callbacks.onStreamStats(stats)
        intervalFrameCount = 0
        lastStatsTime = now
    }

    // MARK: - Helpers

    /// Reverse the server-side zero-byte escaping: 00 FF -> 00, FF FF -> FF.
    /// Mirrors web SEIExtractor.unescapeZeroBytes.
    private func unescapeZeroBytes(_ data: Data) -> Data {
        guard !data.isEmpty else { return data }
        var out = Data()
        out.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if i + 1 < bytes.count {
                let n = bytes[i + 1]
                if b == 0x00 && n == 0xFF {
                    out.append(0x00); i += 2; continue
                }
                if b == 0xFF && n == 0xFF {
                    out.append(0xFF); i += 2; continue
                }
            }
            out.append(b)
            i += 1
        }
        return out
    }

    private func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let i0 = data.startIndex + offset
        return UInt32(data[i0])
            | (UInt32(data[i0 + 1]) << 8)
            | (UInt32(data[i0 + 2]) << 16)
            | (UInt32(data[i0 + 3]) << 24)
    }

    /// Inflate a zlib (deflate) stream — server uses deflate (not gzip) to
    /// avoid H.264 emulation-prevention issues with gzip's mtime field.
    private func inflateZlib(_ data: Data) -> Data? {
        // ZLIB_DECODE uses the raw deflate decoder; zlib header (2 bytes) is
        // stripped manually first.
        guard data.count >= 2 else { return nil }
        let raw = Data(data[(data.startIndex + 2)...])
        return inflateRawDeflate(raw)
    }

    private func inflateRawDeflate(_ data: Data) -> Data? {
        let capacityMultiplier = 16
        var dstSize = max(64, data.count * capacityMultiplier)
        for _ in 0..<4 {
            var out = Data(count: dstSize)
            let written = out.withUnsafeMutableBytes { (outBuf: UnsafeMutableRawBufferPointer) -> Int in
                data.withUnsafeBytes { (inBuf: UnsafeRawBufferPointer) -> Int in
                    guard let outBase = outBuf.bindMemory(to: UInt8.self).baseAddress,
                          let inBase = inBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(outBase, dstSize, inBase, data.count, nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 && written < dstSize {
                out.removeSubrange(written..<out.count)
                return out
            }
            if written == dstSize {
                // Possibly truncated — grow and retry.
                dstSize *= 4
                continue
            }
            return nil
        }
        return nil
    }
}
