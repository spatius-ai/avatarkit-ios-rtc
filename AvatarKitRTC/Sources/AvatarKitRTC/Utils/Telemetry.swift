@_spi(RTC) import AvatarKit

/// Telemetry helpers for AvatarKitRTC. Piggybacks on AvatarKit's already-
/// initialized PostHog channel via the `@_spi(RTC)` RTCTelemetry entry —
/// same pattern as the web SDK reusing avatarkit's PostHog instance.
enum Telemetry {
    enum Level { case info, warning, error }

    /// Low-cardinality metric label.
    ///
    /// Declared here rather than aliased to the host SDK's `LabelValue`: that
    /// type is `@_spi(RTC)`, and its cases stay SPI-protected through a
    /// typealias, so every call site would need the SPI import just to write
    /// `.string(…)`. Keeping our own mirror leaves Telemetry as the one place
    /// this package reaches into AvatarKit's internals.
    enum Label {
        case string(String)
        case bool(Bool)
        case int(Int64)
        case double(Double)

        fileprivate var spiValue: RTCTelemetry.LabelValue {
            switch self {
            case .string(let s): return .string(s)
            case .bool(let b):   return .bool(b)
            case .int(let i):    return .int(i)
            case .double(let d): return .double(d)
            }
        }

        /// The label as its underlying JSON type, so the recorded file shows
        /// whether a value kept its native type or was stringified on the way
        /// out — the alignment question that motivated recording labels at all.
        fileprivate var recordedValue: Any {
            switch self {
            case .string(let s): return s
            case .bool(let b):   return b
            case .int(let i):    return i
            case .double(let d): return d
            }
        }
    }

    static func event(
        _ name: String,
        level: Level = .info,
        _ props: [String: Sendable] = [:]
    ) {
        let mapped: RTCTelemetry.Level
        switch level {
        case .info:    mapped = .info
        case .warning: mapped = .warning
        case .error:   mapped = .error
        }
        let merged = props.merging(common()) { current, _ in current }
        TelemetryRecorder.shared.record(
            channel: "event",
            name: name,
            fields: ["level": String(describing: level), "props": merged]
        )
        RTCTelemetry.track(mapped, name, merged)
    }

    static func metric(
        _ name: String,
        _ props: [String: Sendable] = [:]
    ) {
        var merged = props.merging(common()) { current, _ in current }
        merged["telemetry_kind"] = "metric"
        TelemetryRecorder.shared.record(
            channel: "event", name: name, fields: ["level": "info", "props": merged]
        )
        RTCTelemetry.track(.info, name, merged)
    }

    /// Numeric measurement onto AvatarKit's OTel metric pipeline.
    ///
    /// Distinct from `metric(_:_:)` above, which despite the name only emits an
    /// event carrying a `telemetry_kind` tag — useful as a marker, but never
    /// aggregated into a histogram. This one records an actual data point.
    ///
    /// - Parameters:
    ///   - labels: **low-cardinality** only (provider, end_reason). Per-round
    ///     identity does not belong here; it would create one time series per
    ///     round. Use the event channel to look at a single round.
    static func recordMetric(
        _ name: String,
        _ value: Double,
        labels: [String: Telemetry.Label] = [:]
    ) {
        var merged = labels.mapValues { $0.spiValue }
        merged["service_module"] = .string("rtc")
        TelemetryRecorder.shared.record(
            channel: "metric",
            name: name,
            fields: [
                "value": value,
                // Recorded as the host receives them, so a label that is meant
                // to stay a number is visibly still a number here.
                "labels": labels.mapValues { $0.recordedValue }
                    .merging(["service_module": "rtc"]) { current, _ in current },
            ]
        )
        RTCTelemetry.metric(name, value, labels: merged)
    }

    /// One round of playback, as a trace.
    ///
    /// Wraps the host handle so spans are mirrored alongside the other three
    /// channels. Without this the trace would be the one channel absent from
    /// the local file, and it is the channel that carries the round's shape.
    static func startPlaybackTrace(
        _ conversationId: String,
        startTimeMs: Int64?,
        attrs: [String: Any] = [:]
    ) -> PlaybackTrace? {
        TelemetryRecorder.shared.record(
            channel: "trace",
            name: "playback_trace_start",
            fields: [
                "conversation_id": conversationId,
                "start_ms": startTimeMs as Any,
                "attrs": attrs,
            ]
        )
        // Recorded before the guard: a trace that never starts because tracing
        // is off is itself the finding, and it would be invisible otherwise.
        guard let inner = RTCTelemetry.startPlaybackTrace(
            conversationId, startTimeMs: startTimeMs, attrs: attrs
        ) else { return nil }
        return PlaybackTrace(inner, conversationId: conversationId)
    }

    /// Recording wrapper around the host's trace handle.
    final class PlaybackTrace {
        private let inner: RTCTelemetry.PlaybackTrace
        private let conversationId: String

        fileprivate init(_ inner: RTCTelemetry.PlaybackTrace, conversationId: String) {
            self.inner = inner
            self.conversationId = conversationId
        }

        func span(
            _ name: String,
            _ startMs: Int64,
            _ endMs: Int64,
            _ attrs: [String: Any] = [:],
            isError: Bool = false
        ) {
            TelemetryRecorder.shared.record(
                channel: "trace",
                name: "span",
                fields: [
                    "conversation_id": conversationId,
                    "span": name,
                    "start_ms": startMs,
                    "end_ms": endMs,
                    "dur_ms": endMs - startMs,
                    "is_error": isError,
                    "attrs": attrs,
                ]
            )
            inner.span(name, startMs, endMs, attrs, isError: isError)
        }

        func end(endTimeMs: Int64? = nil, attrs: [String: Any] = [:]) {
            TelemetryRecorder.shared.record(
                channel: "trace",
                name: "playback_trace_end",
                fields: [
                    "conversation_id": conversationId,
                    "end_ms": endTimeMs as Any,
                    "attrs": attrs,
                ]
            )
            inner.end(endTimeMs: endTimeMs, attrs: attrs)
        }
    }

    private static func common() -> [String: Sendable] {
        ["service_module": "rtc"]
    }
}
