import SwiftUI
import UIKit
import Combine

struct IntegrationTestView: View {
    @StateObject private var vm = IntegrationTestViewModel()

    var body: some View {
        VStack(spacing: 0) {
            AvatarContainerView(containerView: vm.containerView)
                .frame(height: 220)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            modeSection
                .padding(.horizontal, 12)
                .padding(.top, 8)

            configSection
                .padding(.horizontal, 12)
                .padding(.top, 8)

            if vm.isRunning {
                VStack(spacing: 4) {
                    ProgressView(value: Double(vm.currentIndex),
                                 total: Double(vm.totalCount))
                    Text("\(vm.currentIndex)/\(vm.totalCount) — \(vm.currentCaseName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

            HStack(spacing: 8) {
                Button(vm.isRunning ? "Running..." : (vm.mode == .mock ? "Run Mock" : "Run Live")) {
                    vm.runAll()
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isRunning
                              || vm.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                              || vm.appID.trimmingCharacters(in: .whitespaces).isEmpty
                              || vm.avatarID.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Stop") { vm.stop() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!vm.isRunning)
                Button("Copy Report") {
                    UIPasteboard.general.string = vm.reportText
                }
                .buttonStyle(.bordered)
                .disabled(vm.reportText.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if !vm.summary.isEmpty {
                Text(vm.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }

            Divider().padding(.top, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(vm.results, id: \.index) { r in
                        TestResultRow(result: r)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .navigationTitle("RTC Integration Test")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var modeSection: some View {
        Picker("Mode", selection: $vm.mode) {
            Text("Mock (no network)").tag(RunnerMode.mock)
            Text("Live (Agora)").tag(RunnerMode.live)
        }
        .pickerStyle(.segmented)
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
}

private struct TestResultRow: View {
    let result: TestResult

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                Text(badge)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor)
                    .cornerRadius(4)
                Text("\(result.index). \(result.name)")
                    .font(.caption)
                    .lineLimit(2)
                Spacer()
                Text(String(format: "%.1fs", Double(result.durationMs) / 1000.0))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let err = result.error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .padding(.leading, 36)
            }
        }
    }

    private var badge: String { result.status.rawValue }
    private var badgeColor: Color {
        switch result.status {
        case .pass: return .green
        case .fail: return .red
        case .skip: return .gray
        }
    }
}

private struct AvatarContainerView: UIViewRepresentable {
    let containerView: UIView
    func makeUIView(context: Context) -> UIView { containerView }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

@MainActor
final class IntegrationTestViewModel: ObservableObject {
    @AppStorage("rtc_base_url") var baseURL: String = ""
    @AppStorage("rtc_app_id")   var appID: String = ""
    @AppStorage("rtc_avatar_id") var avatarID: String = ""

    let containerView: UIView = {
        let v = UIView()
        v.backgroundColor = .black
        v.layer.cornerRadius = 8
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    @Published var mode: RunnerMode = .mock
    @Published var isRunning = false
    @Published var currentIndex = 0
    @Published var totalCount = 0
    @Published var currentCaseName = ""
    @Published var results: [TestResult] = []
    @Published var summary = ""
    @Published var reportText = ""

    private var runner: TestRunner?

    func runAll() {
        guard !isRunning else { return }
        let trimmedAvatar = avatarID.trimmingCharacters(in: .whitespaces)
        let trimmedApp    = appID.trimmingCharacters(in: .whitespaces)
        let trimmedURL    = baseURL.trimmingCharacters(in: .whitespaces)
        guard !trimmedAvatar.isEmpty, !trimmedApp.isEmpty, !trimmedURL.isEmpty else { return }

        results = []
        summary = ""
        reportText = ""
        isRunning = true

        let cases: [TestCase]
        switch mode {
        case .mock: cases = MockTestCases.all
        case .live: cases = TestCases.all
        }
        totalCount = cases.count
        currentIndex = 0
        currentCaseName = ""

        let runner = TestRunner(
            mode: mode,
            cases: cases,
            onProgress: { [weak self] idx, total, name in
                Task { @MainActor [weak self] in
                    self?.currentIndex = idx
                    self?.totalCount = total
                    self?.currentCaseName = name
                }
            },
            onResult: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.results.append(result)
                }
            }
        )
        self.runner = runner

        let pcm = loadBundledPCM()

        Task { @MainActor [weak self] in
            guard let self else { return }
            let finalResults = await runner.run(
                container: containerView,
                baseURL: trimmedURL,
                appId: trimmedApp,
                avatarId: trimmedAvatar,
                pcmData: pcm
            )
            let passed = finalResults.filter { $0.status == .pass }.count
            let failed = finalResults.filter { $0.status == .fail }.count
            let total = finalResults.count
            self.summary = "\(passed)/\(total) passed" + (failed > 0 ? ", \(failed) failed" : "")
            self.reportText = TestRunner.generateReport(results: finalResults)
            self.isRunning = false
            self.runner = nil
        }
    }

    func stop() {
        runner?.abort()
    }

    private func loadBundledPCM() -> Data {
        if let url = Bundle.main.url(forResource: "test-audio", withExtension: "pcm"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return Data()
    }
}
