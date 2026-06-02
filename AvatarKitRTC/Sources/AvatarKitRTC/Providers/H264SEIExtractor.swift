import Foundation

/// Slices an Annex-B H.264 bitstream into NAL units and extracts SEI
/// user_data_unregistered payloads.
///
/// On the web side Agora's JS SDK already does this slicing for us and fires
/// `'sei-received'` events — on iOS we have to do it ourselves because
/// Agora's ObjC API only surfaces the raw encoded bitstream via
/// `IVideoEncodedFrameObserver`.
///
/// **Output format note:** the returned payloads are the bytes after the
/// SEI header — i.e. what the web `SEIExtractor.processSEIData` consumes
/// directly. If the server prepends a UUID before its `[1B flags][4B msgLen]`
/// header you'll need to strip it inside `SEIPacketParser`, not here, since
/// this layer can't tell which SEIs belong to us.
enum H264SEIExtractor {

    /// Scan an Annex-B framed bitstream and return all SEI
    /// user_data_unregistered payloads.
    static func extractUserDataPayloads(from nalStream: Data) -> [Data] {
        var out: [Data] = []
        for nalu in iterateNALUs(in: nalStream) {
            out.append(contentsOf: parseSEINALU(nalu))
        }
        return out
    }

    /// Diagnostic: list NAL unit types found in the buffer using both Annex-B
    /// (start-code) and AVCC (4-byte length prefix) framing assumptions.
    static func diagnose(_ data: Data) -> String {
        let annexb = iterateNALUs(in: data).prefix(8).map { ($0.first ?? 0) & 0x1F }
        let avcc = iterateAVCC(in: data).prefix(8).map { ($0.first ?? 0) & 0x1F }
        return "annexb_types=\(annexb) avcc_types=\(avcc)"
    }

    /// Try parsing the buffer as AVCC (4-byte BE length + NAL payload, repeated).
    /// Returns the discovered NAL payloads; empty if the framing doesn't fit.
    static func iterateAVCC(in stream: Data) -> [Data] {
        var nalus: [Data] = []
        let bytes = [UInt8](stream)
        var i = 0
        while i + 4 <= bytes.count {
            let length = (Int(bytes[i]) << 24) | (Int(bytes[i+1]) << 16) |
                         (Int(bytes[i+2]) << 8) | Int(bytes[i+3])
            i += 4
            if length <= 0 || i + length > bytes.count {
                return [] // not AVCC
            }
            nalus.append(Data(bytes[i..<(i+length)]))
            i += length
        }
        return nalus
    }

    // MARK: - NAL slicing

    /// Iterate NAL units in an Annex-B framed bitstream (starts with 00 00 00 01
    /// or 00 00 01). Returns each NALU's payload bytes (excluding the start code).
    static func iterateNALUs(in stream: Data) -> [Data] {
        var nalus: [Data] = []
        let bytes = [UInt8](stream)
        guard bytes.count >= 3 else { return nalus }

        var starts: [Int] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
                starts.append(i + 3)
                i += 3
            } else if i + 3 < bytes.count &&
                        bytes[i] == 0 && bytes[i + 1] == 0 &&
                        bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                starts.append(i + 4)
                i += 4
            } else {
                i += 1
            }
        }

        for (idx, start) in starts.enumerated() {
            let end = idx + 1 < starts.count ? starts[idx + 1] - 3 : bytes.count
            // Trim trailing zeros that precede the next start code (best-effort).
            var cutoff = end
            while cutoff > start && bytes[cutoff - 1] == 0 { cutoff -= 1 }
            if cutoff <= start { continue }
            nalus.append(Data(bytes[start..<cutoff]))
        }
        return nalus
    }

    // MARK: - SEI parsing

    /// Parse a single NAL unit. If it is an SEI NALU return every
    /// user_data_unregistered payload it carries.
    static func parseSEINALU(_ nalu: Data) -> [Data] {
        guard nalu.count >= 1 else { return [] }
        let nalHeader = nalu[nalu.startIndex]
        let nalType = nalHeader & 0x1F
        guard nalType == 6 else { return [] }  // 6 = SEI

        // NAL RBSP body (after the 1-byte header) — strip emulation prevention.
        let rbsp = ebspToRbsp(Data(nalu[(nalu.startIndex + 1)...]))

        var payloads: [Data] = []
        var offset = 0
        while offset < rbsp.count {
            // payloadType (unsigned, ff*..XX)
            var payloadType = 0
            while offset < rbsp.count && rbsp[rbsp.startIndex + offset] == 0xFF {
                payloadType += 255
                offset += 1
            }
            if offset >= rbsp.count { break }
            payloadType += Int(rbsp[rbsp.startIndex + offset])
            offset += 1

            // payloadSize (unsigned, ff*..XX)
            var payloadSize = 0
            while offset < rbsp.count && rbsp[rbsp.startIndex + offset] == 0xFF {
                payloadSize += 255
                offset += 1
            }
            if offset >= rbsp.count { break }
            payloadSize += Int(rbsp[rbsp.startIndex + offset])
            offset += 1

            if offset + payloadSize > rbsp.count { break }

            // Accept both user_data_unregistered (type 5) and the custom SEI
            // payloadType the egress server uses for AvatarKit (101). The web
            // SDK lets Agora's JS layer surface the payload already, so it
            // never needs to filter by type — we do, because we slice NAL
            // units ourselves and would otherwise pick up unrelated SEIs.
            if payloadType == 5 || payloadType == 101 {
                let start = rbsp.startIndex + offset
                let end = start + payloadSize
                payloads.append(Data(rbsp[start..<end]))
            }
            offset += payloadSize
        }
        return payloads
    }

    /// Remove H.264 emulation-prevention bytes (0x03 inserted after 00 00).
    static func ebspToRbsp(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        var zeroCount = 0
        for byte in data {
            if zeroCount >= 2 && byte == 0x03 {
                zeroCount = 0
                continue
            }
            out.append(byte)
            if byte == 0x00 {
                zeroCount += 1
            } else {
                zeroCount = 0
            }
        }
        return out
    }
}
