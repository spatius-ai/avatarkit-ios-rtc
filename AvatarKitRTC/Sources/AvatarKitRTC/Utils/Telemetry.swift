@_spi(RTC) import AvatarKit

/// Telemetry helpers for AvatarKitRTC. Piggybacks on AvatarKit's already-
/// initialized PostHog channel via the `@_spi(RTC)` RTCTelemetry entry —
/// same pattern as the web SDK reusing avatarkit's PostHog instance.
enum Telemetry {
    enum Level { case info, warning, error }

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

    private static func common() -> [String: Sendable] {
        ["service_module": "rtc"]
    }
}
