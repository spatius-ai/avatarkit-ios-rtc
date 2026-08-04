import Foundation

/// Conversation ID generation for AvatarKitRTC.
///
/// Format matches web-sdk and the main SDK exactly so all of them read the same
/// way: UTC timestamp (YYYYMMDDHHmmss) + underscore + 12-character NanoID.
/// Example: `20251027143034_aB3dEf9hIjKl`
///
/// Unlike the main SDK, the RTC SDK never receives a conversation id — audio
/// goes up through the RTC provider to the agent, which drives the avatar
/// service on our behalf, so nothing in the downstream animation carries a
/// request id. The id is therefore generated locally, once per playback round,
/// purely to correlate this SDK's own telemetry (events, metrics, trace). It is
/// deliberately NOT presented as the server's conversation id.
///
/// Aligned with web's `conversation-id.ts`.
enum ConversationId {
    /// URL-safe alphabet: A-Z, a-z, 0-9 (62 chars), matching web.
    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    )
    private static let nanoidLength = 12

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMddHHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Generate a conversation id for one playback round.
    ///
    /// The modulo over 62 is very slightly biased (256 % 62 != 0), but this id
    /// only has to be unique within a session's telemetry, not unpredictable,
    /// so the bias is irrelevant — same trade the web implementation makes.
    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: nanoidLength)
        if SecRandomCopyBytes(kSecRandomDefault, nanoidLength, &bytes) != errSecSuccess {
            for i in 0..<nanoidLength { bytes[i] = UInt8.random(in: 0...255) }
        }
        let nano = String(bytes.map { alphabet[Int($0) % alphabet.count] })
        return "\(formatter.string(from: Date()))_\(nano)"
    }
}
