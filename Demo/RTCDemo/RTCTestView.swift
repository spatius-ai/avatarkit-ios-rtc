import SwiftUI
import Combine
import AVFoundation
import AvatarKit
import AvatarKitRTC

/// End-to-end Agora RTC playback test.
///
/// Talks to the AvatarKit backend whose base URL the user supplies at runtime,
/// fetches an Agora token + channel from `{baseURL}/api/agora-token`, then
/// hands the realtime animation stream off to `AvatarPlayer`.
struct RTCTestView: View {
    @StateObject private var vm = RTCTestViewModel()

    var body: some View {
        VStack(spacing: 0) {
            avatarSection
                .frame(maxWidth: .infinity, minHeight: 320)
                .background(Color.black)

            Divider()

            statusSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            configSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            controlsSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Divider()

            statsSection
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

            Spacer(minLength: 0)
        }
        .navigationTitle("RTC Test (Agora)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.initializeSDK() }
        .onDisappear {
            // Detached so the cleanup doesn't get cancelled when the view
            // (and its @StateObject) is torn down by NavigationStack.
            let captured = vm
            Task.detached { await captured.disconnect() }
        }
    }

    @ViewBuilder
    private var avatarSection: some View {
        ZStack {
            if let avatar = vm.avatar {
                RTCAvatarViewWrapper(avatar: avatar) { view in
                    vm.attach(avatarView: view)
                }
            } else if vm.isLoadingAvatar {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(vm.loadingMessage).foregroundStyle(.gray).font(.caption)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 50)).foregroundStyle(.gray)
                    Text("Enter an Avatar ID, then Load Avatar")
                        .foregroundStyle(.gray).font(.caption)
                }
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 16) {
                Label {
                    Text(vm.connectionStateText).font(.caption)
                } icon: {
                    Circle().fill(vm.connectionStateColor).frame(width: 8, height: 8)
                }
                Label {
                    Text(vm.isMicPublished ? "Mic ON" : "Mic OFF").font(.caption)
                } icon: {
                    Image(systemName: vm.isMicPublished ? "mic.fill" : "mic.slash.fill")
                        .foregroundStyle(vm.isMicPublished ? .green : .gray)
                }
                Spacer()
            }
            if !vm.lastError.isEmpty {
                Text(vm.lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Backend base URL", text: $vm.baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption)
                .textFieldStyle(.roundedBorder)
            TextField("App ID", text: $vm.appID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption)
                .textFieldStyle(.roundedBorder)
            TextField("Avatar ID", text: $vm.avatarID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var controlsSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    vm.loadAvatar()
                } label: {
                    Label("Load Avatar", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.isLoadingAvatar
                          || vm.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                          || vm.appID.trimmingCharacters(in: .whitespaces).isEmpty
                          || vm.avatarID.trimmingCharacters(in: .whitespaces).isEmpty)

                if vm.isConnected {
                    Button {
                        Task { await vm.disconnect() }
                    } label: {
                        Label("Disconnect", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        Task { await vm.connect() }
                    } label: {
                        Label("Connect", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.avatar == nil || vm.isConnecting)
                }
            }
            if vm.isConnected {
                Button {
                    Task { await vm.toggleMic() }
                } label: {
                    Label(vm.isMicPublished ? "Mute Mic" : "Unmute Mic",
                          systemImage: vm.isMicPublished ? "mic.slash" : "mic")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var statsSection: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("FPS").font(.caption2).foregroundStyle(.secondary)
                Text(vm.statsFPS).font(.caption).monospacedDigit()
                Text("Frames").font(.caption2).foregroundStyle(.secondary)
                Text("\(vm.statsTotalFrames)").font(.caption).monospacedDigit()
            }
            GridRow {
                Text("Lost").font(.caption2).foregroundStyle(.secondary)
                Text("\(vm.statsLost)").font(.caption).monospacedDigit()
                Text("Dropped").font(.caption2).foregroundStyle(.secondary)
                Text("\(vm.statsDropped)").font(.caption).monospacedDigit()
            }
        }
    }
}

// MARK: - ViewModel

@MainActor
final class RTCTestViewModel: ObservableObject {
    // Persisted configuration
    @AppStorage("rtc_base_url") var baseURL: String = ""
    @AppStorage("rtc_app_id")   var appID: String = ""
    @AppStorage("rtc_avatar_id") var avatarID: String = ""

    private let agentUID: UInt = 1000

    @Published var avatar: Avatar?
    @Published var isLoadingAvatar = false
    @Published var loadingMessage = ""
    @Published var lastError = ""

    @Published var isConnecting = false
    @Published var isConnected = false
    @Published var connectionStateText = "Disconnected"
    @Published var connectionStateColor: Color = .gray
    @Published var isMicPublished = false

    @Published var statsFPS: String = "-"
    @Published var statsTotalFrames: Int = 0
    @Published var statsLost: Int = 0
    @Published var statsDropped: Int = 0

    private var avatarView: AvatarView?
    private var provider: AgoraProvider?
    private var player: AvatarPlayer?

    func initializeSDK() {
        let trimmedApp = appID.trimmingCharacters(in: .whitespaces)
        guard !trimmedApp.isEmpty else { return }
        AvatarSDK.initialize(
            appID: trimmedApp,
            configuration: Configuration(
                audioFormat: AudioFormat(sampleRate: 16000),
                drivingServiceMode: .direct,
                logLevel: .warning
            )
        )
    }

    func attach(avatarView: AvatarView) {
        self.avatarView = avatarView
    }

    func loadAvatar() {
        let id = avatarID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        isLoadingAvatar = true
        loadingMessage = "Loading avatar..."
        lastError = ""

        initializeSDK()

        Task {
            do {
                let loaded: Avatar
                if let cached = AvatarManager.shared.retrieve(id: id) {
                    loaded = cached
                } else {
                    loaded = try await AvatarManager.shared.load(id: id) { [weak self] p in
                        guard let self else { return }
                        let total = Double(p.totalUnitCount)
                        if total > 0 {
                            let pct = Int(Double(p.completedUnitCount) / total * 100)
                            self.loadingMessage = "Downloading... \(pct)%"
                        }
                    }
                }
                avatar = loaded
                isLoadingAvatar = false
            } catch {
                isLoadingAvatar = false
                lastError = "Load failed: \(error.localizedDescription)"
            }
        }
    }

    func connect() async {
        guard let avatarView, !isConnecting else { return }
        guard !isConnected else { return }

        let id = avatarID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            lastError = "Avatar ID required"
            return
        }

        isConnecting = true
        defer { isConnecting = false }
        lastError = ""
        updateConnectionState(.connecting)

        // Pre-request mic permission so Agora doesn't fail silently. Agora's
        // mic publish path needs the OS prompt to be answered before join.
        let micGranted = await requestMicPermission()
        if !micGranted {
            lastError = "Microphone permission denied — open Settings → Avatar → Microphone"
            print("[RTCTest] mic permission denied")
        }

        do {
            let token = try await fetchAgoraToken(avatarID: id)
            print("[RTCTest] got token, channel=\(token.channelName) uid=\(token.uid)")
            let provider = AgoraProvider()
            let player = AvatarPlayer(
                provider: provider,
                avatarView: avatarView,
                options: AvatarPlayerOptions(logLevel: .info)
            )
            player.subscribe { [weak self] event in
                Task { @MainActor in self?.handlePlayerEvent(event) }
            }
            self.provider = provider
            self.player = player

            try await player.connect(AgoraConnectionConfig(
                appId: token.appId,
                channel: token.channelName,
                token: token.token,
                uid: token.uid
            ))
            isConnected = true
            updateConnectionState(.connected)

            if micGranted {
                do {
                    try await player.publishAudio()
                    isMicPublished = true
                    print("[RTCTest] mic published")
                } catch {
                    print("[RTCTest] publishAudio failed: \(error.localizedDescription)")
                    lastError = "Mic publish failed: \(error.localizedDescription)"
                }
            }
        } catch {
            lastError = "Connect failed: \(error.localizedDescription)"
            updateConnectionState(.failed)
            await disconnect()
        }
    }

    func toggleMic() async {
        guard let player else { return }
        do {
            if isMicPublished {
                await player.unpublishAudio()
                isMicPublished = false
                print("[RTCTest] mic unpublished")
            } else {
                let granted = await requestMicPermission()
                if !granted {
                    lastError = "Microphone permission denied"
                    return
                }
                try await player.publishAudio()
                isMicPublished = true
                print("[RTCTest] mic re-published")
            }
        } catch {
            lastError = "Mic toggle failed: \(error.localizedDescription)"
            print("[RTCTest] toggleMic failed: \(error.localizedDescription)")
        }
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        }
    }

    func disconnect() async {
        print("[RTCTest] disconnect() start, hasPlayer=\(player != nil)")
        if let player {
            await player.disconnect()
        }
        player = nil
        provider = nil
        isConnected = false
        isMicPublished = false
        updateConnectionState(.disconnected)
        statsFPS = "-"
        statsTotalFrames = 0
        statsLost = 0
        statsDropped = 0
        print("[RTCTest] disconnect() done")
    }

    deinit {
        print("[RTCTest] ViewModel deinit (hasPlayer=\(player != nil))")
    }

    // MARK: - Backend

    private struct AgoraTokenResponse: Decodable {
        let appId: String
        let channelName: String
        let token: String
        let uid: UInt
    }

    private func fetchAgoraToken(avatarID: String) async throws -> AgoraTokenResponse {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces) + "/api/agora-token") else {
            throw NSError(domain: "RTCTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "participantName": "ios-demo",
            "avatarId": avatarID,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "RTCTest", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(msg)"])
        }
        return try JSONDecoder().decode(AgoraTokenResponse.self, from: data)
    }

    // MARK: - Player events

    private func handlePlayerEvent(_ event: AvatarPlayerEvent) {
        switch event {
        case .connected:
            updateConnectionState(.connected)
        case .disconnected:
            isConnected = false
            updateConnectionState(.disconnected)
        case .error(let msg):
            lastError = msg
        case .stalled:
            lastError = "Stream stalled (no frames for 5s)"
        case .connectionStateChanged(let state):
            updateConnectionState(state)
        }
    }

    private func updateConnectionState(_ state: RTCConnectionState) {
        switch state {
        case .disconnected:
            connectionStateText = "Disconnected"
            connectionStateColor = .gray
        case .connecting:
            connectionStateText = "Connecting..."
            connectionStateColor = .orange
        case .connected:
            connectionStateText = "Connected"
            connectionStateColor = .green
        case .reconnecting:
            connectionStateText = "Reconnecting..."
            connectionStateColor = .orange
        case .failed:
            connectionStateText = "Failed"
            connectionStateColor = .red
        }
    }
}

// MARK: - AvatarView wrapper

private struct RTCAvatarViewWrapper: UIViewRepresentable {
    let avatar: Avatar
    let onCreated: (AvatarView) -> Void

    func makeUIView(context: Context) -> AvatarView {
        let view = AvatarView(avatar: avatar)
        view.isOpaque = false
        onCreated(view)
        return view
    }

    func updateUIView(_ uiView: AvatarView, context: Context) {}
}
