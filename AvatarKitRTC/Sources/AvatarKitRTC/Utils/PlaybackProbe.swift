import Foundation

/// Records when each frame actually reached the screen, to a file the demo can
/// hand off after a run.
///
/// The playback clock's whole job is to put one frame on screen every 40ms, and
/// whether it does is only answerable against a real stream on a real device —
/// simulators and unit tests both pace time too kindly to reproduce a late
/// callback or a blocked main thread. Reading that back out of the device log
/// means scrolling thousands of lines for the handful either side of a
/// hand-over, so the series is written to a CSV in Documents instead.
///
/// **Disabled by default.** The demo turns it on; nothing else does, and a
/// shipped integration never pays for it.
public final class PlaybackProbe: @unchecked Sendable {
    public static let shared = PlaybackProbe()

    private let lock = NSLock()
    private var isEnabled = false
    private var rows: [String] = []
    private var startedAt: TimeInterval = 0

    private init() {}

    /// Begin a fresh capture, discarding anything held from a previous run.
    public static func start() {
        let probe = PlaybackProbe.shared
        probe.lock.lock()
        defer { probe.lock.unlock() }
        probe.isEnabled = true
        probe.rows = []
        probe.startedAt = Date().timeIntervalSince1970 * 1000
    }

    /// Stop capturing and write the series out.
    /// - Returns: the file written, or nil if capture was never started or
    ///   produced nothing.
    @discardableResult
    public static func stopAndWrite() -> URL? {
        let probe = PlaybackProbe.shared
        probe.lock.lock()
        let captured = probe.rows
        probe.isEnabled = false
        probe.rows = []
        probe.lock.unlock()

        guard !captured.isEmpty else { return nil }

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let out = dir.appendingPathComponent("rtc_playback_\(stamp).csv")

        let header = "elapsed_ms,source,seq,gap_ms,recovered,slot_requested_ms,slot_actual_ms"
        let text = ([header] + captured).joined(separator: "\n") + "\n"
        do {
            try text.write(to: out, atomically: true, encoding: .utf8)
            return out
        } catch {
            return nil
        }
    }

    func record(source: String, seq: Int?, gapMs: Double, isRecovered: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return }
        let elapsed = Date().timeIntervalSince1970 * 1000 - startedAt
        rows.append(
            "\(Int(elapsed.rounded())),\(source),\(seq.map(String.init) ?? ""),\(Int(gapMs.rounded())),\(isRecovered),,"
        )
    }

    /// Record a slot firing: what delay it was armed with, and how long it
    /// actually took to run. The difference is scheduling latency the grid then
    /// has to absorb, and separates "the clock aimed wrong" from "the clock
    /// aimed right but the main actor was busy" — which the render gaps alone
    /// cannot distinguish.
    func recordSlot(requestedMs: Double, actualMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return }
        let elapsed = Date().timeIntervalSince1970 * 1000 - startedAt
        rows.append(
            "\(Int(elapsed.rounded())),slot,,,,\(Int(requestedMs.rounded())),\(Int(actualMs.rounded()))"
        )
    }
}
