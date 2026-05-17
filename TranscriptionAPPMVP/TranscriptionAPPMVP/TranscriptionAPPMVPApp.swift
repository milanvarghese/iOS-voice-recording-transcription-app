import SwiftUI
import AVFoundation

@main
struct TranscriptionAPPMVPApp: App {
    @StateObject private var auth = AuthViewModel()

    init() {
        Self.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .task { await auth.restoreSession() }
        }
    }

    /// Configure the audio session ONCE at app launch.
    /// .playAndRecord + .defaultToSpeaker + .allowBluetooth = the right defaults
    /// for a recorder that can also play back transcripts/audio later.
    private static func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: [])
        } catch {
            print("⚠️ AVAudioSession setup failed: \(error)")
        }
    }
}
