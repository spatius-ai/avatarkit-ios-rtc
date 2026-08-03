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
        RTCTelemetry.track(mapped, name, props.merging(common()) { current, _ in current })
    }

    static func metric(
        _ name: String,
        _ props: [String: Sendable] = [:]
    ) {
        var merged = props.merging(common()) { current, _ in current }
        merged["telemetry_kind"] = "metric"
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
        RTCTelemetry.metric(name, value, labels: merged)
    }

    private static func common() -> [String: Sendable] {
        ["service_module": "rtc"]
    }
}
