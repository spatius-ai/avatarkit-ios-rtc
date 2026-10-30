import XCTest
@testable import AvatarKitRTC

@available(iOS 16.0, *)
final class AvatarKitRTCTests: XCTestCase {
    func testTypesAreImportable() {
        // Smoke test: ensure the module compiles and key public symbols
        // are accessible. Real coverage lives in the demo app.
        _ = RTCConnectionState.disconnected
    }
}
