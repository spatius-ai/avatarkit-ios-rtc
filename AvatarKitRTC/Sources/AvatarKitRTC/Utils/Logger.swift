import Foundation
import os

/// Log levels exposed to RTC consumers.
public enum RTCLogLevel: String, Sendable {
    case info
    case warning
    case error
    case none
}

/// Internal logger used by AvatarKitRTC. Mirrors web's `logger` so log lines
/// across SDKs are searchable with the same prefix scheme.
struct RTCLogger {
    nonisolated(unsafe) static var currentLevel: RTCLogLevel = .warning

    let category: String
    private let osLogger: os.Logger

    init(_ category: String) {
        self.category = category
        self.osLogger = os.Logger(subsystem: "ai.spatius.avatarkit.rtc", category: category)
    }

    func info(_ message: @autoclosure () -> String) {
        guard priority(.info) >= priority(Self.currentLevel) else { return }
        let text = message()
        #if DEBUG
        print("[RTC][\(category)] \(text)")
        #endif
        osLogger.info("[\(category, privacy: .public)] \(text, privacy: .public)")
    }

    func warn(_ message: @autoclosure () -> String) {
        guard priority(.warning) >= priority(Self.currentLevel) else { return }
        let text = message()
        #if DEBUG
        print("[RTC][\(category)] WARN \(text)")
        #endif
        osLogger.warning("[\(category, privacy: .public)] \(text, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        guard priority(.error) >= priority(Self.currentLevel) else { return }
        let text = message()
        #if DEBUG
        print("[RTC][\(category)] ERROR \(text)")
        #endif
        osLogger.error("[\(category, privacy: .public)] \(text, privacy: .public)")
    }

    private func priority(_ level: RTCLogLevel) -> Int {
        switch level {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        case .none: return 3
        }
    }
}
