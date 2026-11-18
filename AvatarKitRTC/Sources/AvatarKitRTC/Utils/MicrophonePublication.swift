import Foundation

/// Start capture and publication atomically from the caller's point of view.
@MainActor
func startMicrophone(capture: (Bool) -> Int32, publish: (Bool) -> Int32) throws {
    let captureCode = capture(true)
    let publishCode = captureCode == 0 ? publish(true) : 0
    guard captureCode == 0 && publishCode == 0 else {
        // Always stop capture, even if revoking publication fails.
        let revokeCode = publish(false)
        let stopCode = capture(false)
        let code = captureCode != 0 ? captureCode : publishCode
        let stage = captureCode != 0 ? "enableLocalAudio" : "publishMicrophoneTrack"
        throw NSError(domain: "AvatarKitRTC.Microphone", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: "\(stage) failed: \(code); rollback publish=\(revokeCode), capture=\(stopCode)"
        ])
    }
}
