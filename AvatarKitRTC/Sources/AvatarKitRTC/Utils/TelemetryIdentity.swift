import Foundation
@_spi(Internal) import AvatarKit

/// Declares this SDK's telemetry identity to the host.
///
/// Every record would otherwise be attributed to the host SDK
/// (`spatius-ios-sdk` and its version), leaving RTC traffic indistinguishable
/// from a plain AvatarKit integration and this SDK's own version absent from
/// the data entirely.
///
/// **Timing.** The attribution is read when AvatarKit builds its OpenTelemetry
/// Resource, and is fixed from then on. On iOS that build happens inside a Task
/// spawned by `AvatarSDK.initialize()` — after region resolution — rather than
/// synchronously within the call, so a claim made when `AvatarPlayer` is
/// constructed still lands ahead of it. (Android has no such window: its
/// Resource is built synchronously inside initialize(), which is why that SDK
/// declares a ContentProvider to claim the identity before app code runs.)
enum TelemetryIdentity {
    /// This package's version. Hand-written because a Swift package cannot read
    /// its own podspec; **keep in step with `AvatarKitRTC.podspec`**.
    ///
    /// Drifted once already — left at beta.6 through the whole beta.7 release,
    /// which fails silently: the wrong number simply appears on every record,
    /// and nothing in the build catches it.
    static let sdkVersion = "1.0.0-beta.7"

    @MainActor static func claim() {
        AvatarSDK.inject([
            "sdk_package": "spatius-ios-rtc",
            "sdk_version": sdkVersion,
        ])
    }
}
