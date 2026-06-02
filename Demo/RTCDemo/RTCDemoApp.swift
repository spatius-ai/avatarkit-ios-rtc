import SwiftUI
import AVFoundation

@main
struct RTCDemoApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                LauncherView()
            }
        }
    }
}

struct LauncherView: View {
    var body: some View {
        List {
            NavigationLink {
                RTCTestView()
            } label: {
                Label("RTC Demo (Agora)", systemImage: "antenna.radiowaves.left.and.right")
            }
            NavigationLink {
                IntegrationTestView()
            } label: {
                Label("Integration Test", systemImage: "checklist")
            }
        }
        .navigationTitle("AvatarKitRTC")
        .navigationBarTitleDisplayMode(.inline)
    }
}
