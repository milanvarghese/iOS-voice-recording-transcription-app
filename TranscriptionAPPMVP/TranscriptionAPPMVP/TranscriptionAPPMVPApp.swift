import SwiftUI
import AVFoundation
import UserNotifications

@main
struct TranscriptionAPPMVPApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    /// .playAndRecord + .defaultToSpeaker + .allowBluetoothA2DP = the right
    /// defaults for a recorder that can also play back transcripts later.
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

/// Catches taps on the action buttons inside the recording-status
/// notification (Pause / Resume / Stop) and forwards them to the
/// AudioRecorder + UploadQueue singletons.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            RecordingNotificationManager.shared.registerCategoriesIfNeeded()
            // If iOS killed us mid-recording (typically during a phone call),
            // the M4A is on disk. Surface it as pendingOrphan so the Recording
            // tab can offer Continue / Save / Discard.
            AudioRecorder.shared.checkForOrphan()
        }
        return true
    }

    /// Allow the silent recording-status notification to still appear in the
    /// Notification Center when the app is in the foreground (otherwise iOS
    /// suppresses it).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Don't show a banner; let it live in Notification Center only.
        completionHandler([])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        Task { @MainActor in
            switch action {
            case RecordingNotificationManager.pauseActionId:
                AudioRecorder.shared.pause()
            case RecordingNotificationManager.resumeActionId:
                AudioRecorder.shared.resume()
            case RecordingNotificationManager.stopActionId:
                if let pending = await AudioRecorder.shared.stop() {
                    UploadQueue.shared.enqueue(pending)
                }
            default:
                break  // .defaultAction (tap on body) just opens the app
            }
            completionHandler()
        }
    }
}
