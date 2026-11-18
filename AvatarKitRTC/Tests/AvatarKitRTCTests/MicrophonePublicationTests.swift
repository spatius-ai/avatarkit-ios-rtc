import XCTest
@testable import AvatarKitRTC

@MainActor final class MicrophonePublicationTests: XCTestCase {
    func testCaptureFailureDoesNotPublish() {
        var events: [String] = []
        XCTAssertThrowsError(try startMicrophone(capture: { on in events.append("capture:\(on)"); return on ? -5 : 0 }, publish: { on in events.append("publish:\(on)"); return 0 }))
        XCTAssertFalse(events.contains("publish:true"))
        XCTAssertTrue(events.contains("capture:false"))
    }
    func testPublishFailureRollsBackAndAllowsRetry() throws {
        var capturing = false
        var fail = true
        let capture: (Bool) -> Int32 = { capturing = $0; return 0 }
        let publish: (Bool) -> Int32 = { $0 && fail ? -7 : 0 }
        XCTAssertThrowsError(try startMicrophone(capture: capture, publish: publish))
        XCTAssertFalse(capturing)
        fail = false
        try startMicrophone(capture: capture, publish: publish)
        XCTAssertTrue(capturing)
    }
    func testRollbackFailureStillDisablesCapture() {
        var events: [String] = []
        XCTAssertThrowsError(try startMicrophone(capture: { on in events.append("capture:\(on)"); return 0 }, publish: { on in events.append("publish:\(on)"); return on ? -7 : -8 })) { error in
            XCTAssertTrue(error.localizedDescription.contains("-7"))
        }
        XCTAssertEqual(events.last, "capture:false")
    }
    func testSuccessLeavesCaptureEnabled() throws {
        var events: [String] = []
        try startMicrophone(capture: { on in events.append("capture:\(on)"); return 0 }, publish: { on in events.append("publish:\(on)"); return 0 })
        XCTAssertEqual(events, ["capture:true", "publish:true"])
    }
}
