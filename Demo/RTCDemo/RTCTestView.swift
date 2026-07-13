import SwiftUI
import Combine
import AVFoundation
import AvatarKit
import AvatarKitRTC
import AgoraRtcKit

/// End-to-end Agora RTC playback test.
///
/// Connects directly to an Agora channel using credentials supplied through
/// the Config sheet (App ID / channel / token / uid). Useful when the Agora
/// integrator wants to point the demo at their own channel without going
/// through the AvatarKit backend's token issuer.
struct RTCTestView: View {
    @StateObject private var vm = RTCTestViewModel()
    @State private var showConfig = false

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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showConfig = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showConfig) {
            ConfigSheet(vm: vm)
        }
        .onAppear { vm.initializeSDK() }
        .onDisappear {
            // Detached so the cleanup doesn't get cancelled when the view
            // (and its @StateObject) is torn down by NavigationStack.
            let captured = vm
            Task.detached { await captured.disconnectAny() }
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
                    Text(vm.appID.trimmingCharacters(in: .whitespaces).isEmpty
                         || vm.avatarID.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Tap the gear icon to fill App ID + Avatar ID"
                         : "Tap Load Avatar")
                        .foregroundStyle(.gray).font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
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
                          || vm.appID.trimmingCharacters(in: .whitespaces).isEmpty
                          || vm.avatarID.trimmingCharacters(in: .whitespaces).isEmpty)

                if vm.isConnected {
                    Button {
                        Task { await vm.disconnectAny() }
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
            if !vm.isConnected {
                Button {
                    Task { await vm.connectExternalEngine() }
                } label: {
                    Label("Connect (External Engine)", systemImage: "arrow.triangle.branch")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(vm.avatar == nil || vm.isConnecting)
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
    // AvatarKit credentials
    @AppStorage("rtc_app_id")    var appID: String = ""
    @AppStorage("rtc_avatar_id") var avatarID: String = ""

    // Agora credentials — the SDK has no token-fetch logic, the integrator
    // (or their backend) is responsible for supplying all four values.
    @AppStorage("rtc_agora_app_id")  var agoraAppID: String = ""
    @AppStorage("rtc_agora_channel") var agoraChannel: String = ""
    @AppStorage("rtc_agora_token")   var agoraToken: String = ""
    @AppStorage("rtc_agora_uid")     var agoraUID: String = ""

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
    /// Host-owned engine for route B (external engine) verification.
    private var externalEngine: AgoraRtcEngineKit?
    /// True while the current session was established via `attach(to:)` (route B),
    /// so `disconnect()` routes to the host-owned teardown.
    private var usingExternalEngine = false

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
        usingExternalEngine = false
        updateConnectionState(.connecting)

        // Pre-request mic permission so Agora doesn't fail silently. Agora's
        // mic publish path needs the OS prompt to be answered before join.
        let micGranted = await requestMicPermission()
        if !micGranted {
            lastError = "Microphone permission denied — open Settings → Avatar → Microphone"
        }

        let trimmedAgoraApp = agoraAppID.trimmingCharacters(in: .whitespaces)
        let trimmedChannel  = agoraChannel.trimmingCharacters(in: .whitespaces)
        let trimmedToken    = agoraToken.trimmingCharacters(in: .whitespaces)
        let parsedUID       = UInt(agoraUID.trimmingCharacters(in: .whitespaces)) ?? 0

        guard !trimmedAgoraApp.isEmpty, !trimmedChannel.isEmpty else {
            lastError = "Agora App ID and Channel are required (open Config)"
            updateConnectionState(.failed)
            return
        }

        do {
            print("[RTCTest] connecting channel=\(trimmedChannel) uid=\(parsedUID)")
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
                appId: trimmedAgoraApp,
                channel: trimmedChannel,
                token: trimmedToken.isEmpty ? nil : trimmedToken,
                uid: parsedUID
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

    /// Route B verification: the host app owns the Agora engine.
    ///
    /// This mirrors what an integrator who already has their own Agora engine
    /// would write: create the engine, set role, subscribe to encoded video,
    /// then hand it to the player via `attach(to:)` BEFORE joining. The SDK
    /// never creates, joins, or destroys the engine here.
    func connectExternalEngine() async {
        guard let avatarView, !isConnecting, !isConnected else { return }

        isConnecting = true
        defer { isConnecting = false }
        lastError = ""
        updateConnectionState(.connecting)

        // Agora credentials come from the Config sheet — the integrator supplies
        // appId/channel/token/uid from their own backend.
        let trimmedAgoraApp = agoraAppID.trimmingCharacters(in: .whitespaces)
        let trimmedChannel  = agoraChannel.trimmingCharacters(in: .whitespaces)
        let trimmedToken    = agoraToken.trimmingCharacters(in: .whitespaces)
        let parsedUID       = UInt(agoraUID.trimmingCharacters(in: .whitespaces)) ?? 0

        guard !trimmedAgoraApp.isEmpty, !trimmedChannel.isEmpty else {
            lastError = "Agora App ID and Channel are required (open Config)"
            updateConnectionState(.failed)
            return
        }

        usingExternalEngine = true
        do {
            print("[RTCTest-B] host-owned engine, channel=\(trimmedChannel) uid=\(parsedUID)")

            // 1. Host creates and owns the engine.
            let cfg = AgoraRtcEngineConfig()
            cfg.appId = trimmedAgoraApp
            cfg.channelProfile = .liveBroadcasting
            // Route B: the host owns the engine and its delegate. Here the demo
            // passes its own delegate (nil for brevity); an integrator would set
            // their own AgoraRtcEngineDelegate to receive join / connection
            // callbacks — attach(to:) never touches it.
            let engine = AgoraRtcEngineKit.sharedEngine(with: cfg, delegate: nil)
            self.externalEngine = engine

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

            // 2. Attach BEFORE join — installs observer + sets enable_sei.
            try player.attach(to: engine)

            // 3. Host configures subscription + joins the channel itself.
            engine.setClientRole(.broadcaster)
            let opts = AgoraRtcChannelMediaOptions()
            opts.autoSubscribeAudio = true
            opts.autoSubscribeVideo = true
            opts.publishCameraTrack = false
            opts.publishMicrophoneTrack = false
            opts.clientRoleType = .broadcaster
            let rc = engine.joinChannel(
                byToken: trimmedToken.isEmpty ? nil : trimmedToken,
                channelId: trimmedChannel,
                uid: parsedUID,
                mediaOptions: opts
            )
            guard rc == 0 else {
                throw NSError(domain: "RTCTest-B", code: Int(rc),
                              userInfo: [NSLocalizedDescriptionKey: "host joinChannel failed rc=\(rc)"])
            }

            isConnected = true
            updateConnectionState(.connected)
            print("[RTCTest-B] attached + host joined")
        } catch {
            lastError = "Attach failed: \(error.localizedDescription)"
            updateConnectionState(.failed)
            await disconnectExternalEngine()
        }
    }

    /// Routes teardown to the flavour that matches the live session so the
    /// Disconnect button and view teardown work for both connect paths.
    func disconnectAny() async {
        if usingExternalEngine {
            await disconnectExternalEngine()
        } else {
            await disconnect()
        }
    }

    /// Route B teardown: player detaches (observer off), then the host leaves
    /// and destroys its own engine.
    func disconnectExternalEngine() async {
        if let player { await player.detach() }
        if let engine = externalEngine {
            engine.leaveChannel(nil)
            AgoraRtcEngineKit.destroy()
        }
        externalEngine = nil
        player = nil
        provider = nil
        usingExternalEngine = false
        isConnected = false
        updateConnectionState(.disconnected)
        statsFPS = "-"
        statsTotalFrames = 0
        statsLost = 0
        statsDropped = 0
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

// MARK: - Config sheet

private struct ConfigSheet: View {
    @ObservedObject var vm: RTCTestViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("AvatarKit") {
                    LabeledField(title: "App ID", text: $vm.appID)
                    LabeledField(title: "Avatar ID", text: $vm.avatarID)
                }
                Section {
                    LabeledField(title: "App ID", text: $vm.agoraAppID)
                    LabeledField(title: "Channel", text: $vm.agoraChannel)
                    LabeledField(title: "Token", text: $vm.agoraToken)
                    LabeledField(title: "UID", text: $vm.agoraUID, keyboardType: .numberPad)
                } header: {
                    Text("Agora")
                } footer: {
                    Text("Leave Token empty for App-ID-only channels; UID defaults to 0.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Config")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct LabeledField: View {
    let title: String
    @Binding var text: String
    var keyboardType: UIKeyboardType = .default

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 90, alignment: .leading)
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField(title, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboardType)
                .font(.callout)
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
