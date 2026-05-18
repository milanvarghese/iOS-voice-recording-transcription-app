import Foundation
import UserNotifications

/// Posts a silent, persistent local notification that stays in the iOS
/// Notification Center for as long as a recording is in progress. Lets the
/// user see "Recording — 01:23" without unlocking the phone or returning
/// to the app, and exposes Pause / Resume / Stop action buttons inline.
///
/// interruptionLevel = .passive means iOS places it in the Notification
/// Center without sound, vibration, or banner — the right vibe for a
/// status indicator.
@MainActor
final class RecordingNotificationManager {
    static let shared = RecordingNotificationManager()

    // Notification identifiers (must be stable across re-posts)
    private let identifier = "TranscriptionAPPMVP.recording-status"
    private let activeCategoryId = "TranscriptionAPPMVP.notif.category.active"
    private let pausedCategoryId = "TranscriptionAPPMVP.notif.category.paused"

    // Action identifiers — match what AppDelegate's notification handler dispatches on.
    static let pauseActionId = "TranscriptionAPPMVP.notif.pause"
    static let resumeActionId = "TranscriptionAPPMVP.notif.resume"
    static let stopActionId = "TranscriptionAPPMVP.notif.stop"

    private var permissionGranted = false
    private var lastPostedBody = ""
    private var lastPostedCategory = ""
    private var categoriesRegistered = false

    /// Registers the two notification categories (active / paused) with their
    /// action buttons. Call at app launch so categories exist before any
    /// notification posts. Safe to call multiple times.
    func registerCategoriesIfNeeded() {
        guard !categoriesRegistered else { return }
        categoriesRegistered = true

        let pause = UNNotificationAction(
            identifier: Self.pauseActionId,
            title: "Pause",
            options: []
        )
        let resume = UNNotificationAction(
            identifier: Self.resumeActionId,
            title: "Resume",
            options: []
        )
        let stop = UNNotificationAction(
            identifier: Self.stopActionId,
            title: "Stop & Save",
            options: [.destructive]  // shown in red
        )

        let activeCategory = UNNotificationCategory(
            identifier: activeCategoryId,
            actions: [pause, stop],
            intentIdentifiers: [],
            options: []
        )
        let pausedCategory = UNNotificationCategory(
            identifier: pausedCategoryId,
            actions: [resume, stop],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([activeCategory, pausedCategory])
    }

    /// Asks for notification permission on first call. Safe to call repeatedly.
    func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            permissionGranted = true
        case .denied:
            permissionGranted = false
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

    /// Called when recording starts or the elapsed seconds / pause state change.
    /// Re-post is gated on whether the visible body or category actually
    /// changed, so we don't spam the system every 100ms.
    func showRecordingStatus(elapsedSeconds: TimeInterval, isPaused: Bool) {
        Task {
            registerCategoriesIfNeeded()
            await requestPermissionIfNeeded()
            guard permissionGranted else { return }

            let body = format(elapsedSeconds: elapsedSeconds, isPaused: isPaused)
            let category = isPaused ? pausedCategoryId : activeCategoryId
            guard body != lastPostedBody || category != lastPostedCategory else { return }
            lastPostedBody = body
            lastPostedCategory = category

            let content = UNMutableNotificationContent()
            content.title = isPaused
                ? "⏸ TranscriptionAPPMVP — Paused"
                : "🔴 TranscriptionAPPMVP — Recording"
            content.body = body
            content.sound = nil
            content.interruptionLevel = .passive
            content.threadIdentifier = identifier
            content.categoryIdentifier = category

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    /// Called when recording stops, is discarded, or the recorder resets.
    func clearRecordingStatus() {
        lastPostedBody = ""
        lastPostedCategory = ""
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
