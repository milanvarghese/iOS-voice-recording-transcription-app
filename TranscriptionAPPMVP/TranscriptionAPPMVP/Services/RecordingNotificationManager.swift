import Foundation
import UserNotifications

/// Posts a silent, persistent local notification that stays in the iOS
/// Notification Center for as long as a recording is in progress. Lets the
/// user see "Recording — 01:23" without unlocking the phone or returning
/// to the app, and dismisses itself when stop / discard is called.
///
/// We use a single notification with a fixed identifier and re-post it to
/// update the elapsed-time string. interruptionLevel = .passive means iOS
/// places it in the Notification Center without making any sound, vibration,
/// or banner, which is the right vibe for a status indicator.
@MainActor
final class RecordingNotificationManager {
    static let shared = RecordingNotificationManager()

    private let identifier = "TranscriptionAPPMVP.recording-status"
    private var permissionGranted = false
    private var lastPostedBody = ""

    /// Asks for notification permission on first call. Safe to call repeatedly.
    func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permissionGranted = true
            return
        case .denied:
            permissionGranted = false
            return
        case .notDetermined:
            do {
                permissionGranted = try await center.requestAuthorization(options: [.alert])
            } catch {
                permissionGranted = false
            }
        @unknown default:
            permissionGranted = false
        }
    }

    /// Called when recording starts or any time the elapsed seconds change.
    /// Body changes are batched to avoid spamming the system — we only re-post
    /// when the visible string would actually differ.
    func showRecordingStatus(elapsedSeconds: TimeInterval, isPaused: Bool) {
        Task {
            await requestPermissionIfNeeded()
            guard permissionGranted else { return }

            let body = format(elapsedSeconds: elapsedSeconds, isPaused: isPaused)
            guard body != lastPostedBody else { return }
            lastPostedBody = body

            let content = UNMutableNotificationContent()
            content.title = isPaused
                ? "⏸ TranscriptionAPPMVP — Paused"
                : "🔴 TranscriptionAPPMVP — Recording"
            content.body = body
            content.sound = nil
            content.interruptionLevel = .passive    // silent, no banner
            content.threadIdentifier = identifier

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil    // deliver immediately
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Called when recording stops, is discarded, or the recorder is reset.
    func clearRecordingStatus() {
        lastPostedBody = ""
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private func format(elapsedSeconds: TimeInterval, isPaused: Bool) -> String {
        let total = Int(elapsedSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let time: String
        if h > 0 {
            time = String(format: "%d:%02d:%02d", h, m, s)
        } else {
            time = String(format: "%02d:%02d", m, s)
        }
        return isPaused ? "Paused at \(time)" : "Recording \(time)"
    }
}
