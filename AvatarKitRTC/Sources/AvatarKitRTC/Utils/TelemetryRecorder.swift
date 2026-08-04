import Foundation

/// Mirrors every telemetry emission to a local file, as it is handed to the
/// host SDK.
///
/// The four channels (event / metric / log / trace) leave the device for three
/// different backends, so checking that a change reports what it intends to
/// means waiting on ingestion and then reconstructing one round out of three
/// consoles. This writes the same payloads down locally at the moment they are
/// emitted, giving a single ordered file per run to diff against expectations —
/// including the metric labels, which are the part most easily gotten wrong and
/// the part hardest to read back out of an aggregated histogram.
///
/// Recording is passive: it never alters what is sent, and a failure to write
/// is swallowed rather than surfaced, because a diagnostic must not be able to
/// break the playback path it is observing.
///
/// **Capture is always on** (bounded, in memory) so a round that turns out to
/// be interesting can be dumped after the fact — a run worth looking at is
/// usually only recognised once it has already happened. Nothing leaves the
/// process until `write()` is called.
public final class TelemetryRecorder: @unchecked Sendable {
    public static let shared = TelemetryRecorder()

    /// Kept small enough to be irrelevant against playback's own allocations —
    /// a round emits on the order of tens of records, so this holds hundreds of
    /// rounds and still bounds a long-running session.
    private static let maxRecords = 5000

    private let lock = NSLock()
    private var records: [String] = []
    private var dropped = 0

    private init() {}

    // MARK: - Capture

    /// Record one emission. `channel` is the transport it goes out on, which is
    /// what makes the file answer "did this land as a metric or only as an
    /// event" — a distinction the payloads themselves do not carry.
    func record(channel: String, name: String, fields: [String: Any]) {
        var payload: [String: Any] = [
            "ts": Int64((Date().timeIntervalSince1970 * 1000).rounded()),
            "channel": channel,
            "name": name,
        ]
        payload.merge(fields) { current, _ in current }

        // Serialise on the calling thread: JSON conversion is where a
        // non-encodable value would otherwise surface later, far from the call
        // site that produced it.
        let line = Self.jsonLine(payload)

        lock.lock()
        defer { lock.unlock() }
        if records.count >= Self.maxRecords {
            records.removeFirst()
            dropped += 1
        }
        records.append(line)
    }

    // MARK: - Output

    /// Write everything captured so far to Documents, keeping the buffer intact
    /// so a later dump still covers the whole session.
    ///
    /// - Returns: the file written, or nil if nothing has been captured.
    @discardableResult
    public static func write() -> URL? {
        let recorder = TelemetryRecorder.shared
        recorder.lock.lock()
        let captured = recorder.records
        let lost = recorder.dropped
        recorder.lock.unlock()

        guard !captured.isEmpty else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = dir.appendingPathComponent("rtc_telemetry_\(stamp).jsonl")

        var lines = captured
        if lost > 0 {
            // Stated in the file rather than logged: a reader counting rounds
            // needs to know the head was trimmed.
            lines.insert(
                Self.jsonLine([
                    "ts": Int64((Date().timeIntervalSince1970 * 1000).rounded()),
                    "channel": "recorder",
                    "name": "records_dropped",
                    "count": lost,
                ]),
                at: 0
            )
        }

        do {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }

    /// Discard everything captured. Used by the demo to isolate a single run.
    public static func reset() {
        let recorder = TelemetryRecorder.shared
        recorder.lock.lock()
        recorder.records = []
        recorder.dropped = 0
        recorder.lock.unlock()
    }

    // MARK: - Encoding

    /// Encode one record as a single line.
    ///
    /// Values arrive as `Any` from call sites that pass whatever the payload
    /// holds, so anything JSONSerialization would reject is coerced to its
    /// description instead of failing the write — a diagnostic that drops
    /// records because one field had an unexpected type is worse than one that
    /// stringifies it.
    private static func jsonLine(_ payload: [String: Any]) -> String {
        let sanitized = payload.mapValues(sanitize)
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: sanitized, options: [.sortedKeys]
            ),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"error\":\"encode_failed\"}"
        }
        return text
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let v as String: return v
        case let v as Bool:   return v
        case let v as Int:    return v
        case let v as Int64:  return v
        case let v as Double: return v.isFinite ? v : String(describing: v)
        case let v as [Any]:  return v.map(sanitize)
        case let v as [String: Any]: return v.mapValues(sanitize)
        default: return String(describing: value)
        }
    }
}
