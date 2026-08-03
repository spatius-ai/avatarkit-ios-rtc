import Foundation

/// Fetches demo RTC credentials from the internal agent-server, so a device run
/// does not start with six fields to type in by hand.
///
/// Mirrors the web demo's auto-fetch (`demo/src/App.vue`): same endpoint, same
/// request shape, same response fields.
///
/// The endpoint itself is **never** in source — this repository is public. It
/// is read from `DemoSecrets.plist`, which is gitignored, exactly as the web
/// demo reads `VITE_AGENT_SERVER` from a gitignored `.env.local`. Without that
/// file the button reports what is missing and the fields stay manual.
enum DemoCredentials {

    struct Agora {
        let appID: String
        let channel: String
        let token: String
        let uid: String
    }

    enum Failure: LocalizedError {
        case missingEndpoint
        case badStatus(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .missingEndpoint:
                return "AGENT_SERVER not set — add Demo/RTCDemo/DemoSecrets.plist with an AGENT_SERVER key (gitignored)."
            case .badStatus(let code):
                return "agora-token responded \(code)"
            case .malformedResponse:
                return "agora-token response was not the expected shape"
            }
        }
    }

    /// Base URL of the internal agent-server, or nil when the local secrets
    /// file is absent — which is the normal state for anyone outside the team.
    static var agentServer: String? {
        guard let url = Bundle.main.url(forResource: "DemoSecrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let raw = dict["AGENT_SERVER"] as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Trailing slashes would double up against the "/api/..." path.
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    static var isConfigured: Bool { agentServer != nil }

    /// Ask the agent server to mint a channel and token for `avatarID`.
    static func fetchAgora(avatarID: String) async throws -> Agora {
        guard let base = agentServer else { throw Failure.missingEndpoint }

        var request = URLRequest(url: URL(string: "\(base)/api/agora-token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "participantName": "demo-user",
            "avatarId": avatarID.trimmingCharacters(in: .whitespaces),
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.badStatus(status) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let appID = json["appId"] as? String,
              let channel = json["channelName"] as? String,
              let token = json["token"] as? String
        else { throw Failure.malformedResponse }

        // uid comes back as a number; the demo keeps it as text to match the
        // hand-entered field.
        let uid: String
        if let numeric = json["uid"] as? NSNumber {
            uid = numeric.stringValue
        } else if let text = json["uid"] as? String {
            uid = text
        } else {
            uid = ""
        }

        return Agora(appID: appID, channel: channel, token: token, uid: uid)
    }
}
