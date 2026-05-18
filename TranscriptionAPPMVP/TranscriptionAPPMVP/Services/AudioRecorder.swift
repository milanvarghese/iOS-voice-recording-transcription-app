import Foundation
import AVFoundation
import Combine
import UIKit

/// Singleton recorder. Enforces "only one recording session at a time" so two
/// taps on Record can't create two AVAudioRecorders fighting over the mic.
///
/// Design choices and the edge cases each one solves:
///
/// 1. Single shared instance + `isRecording` guard ↦ prevents "two recording
///    sessions cancel each other out" (concern #6).
/// 2. AVAudioRecorder writes M4A to disk continuously. We do not buffer in memory.
///    If the OS kills the app, the partial file remains on disk and `pendingRecording()`
///    will return it on next launch ↦ prevents "recording lost after pause/close"
///    (concern #2) and "recording in progress but timer at zero" (concern #5,
///    because the timer is bound to `recorder.currentTime`).
/// 3. We subscribe to `AVAudioSession.interruptionNotification` and handle phone
///    calls / Siri / other audio apps grabbing the mic by auto-resuming on
///    `.ended`. ↦ prevents "switching apps fails the recording" (concern #8).
/// 4. `isIdleTimerDisabled = true` while recording prevents the lock screen from
///    interrupting long recordings on default settings.
/// 5. We never throw away a file just because the user pauses — pause and resume
///    keep writing to the same file ↦ supports long recordings.
/// 6. `discardCurrentRecording()` is a first-class operation ↦ solves
///    "no way to delete a bad recording mid-session" (concern #4).
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    static let shared = AudioRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0          // 0…1, for the waveform UI
    @Published private(set) var lastError: String?

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var currentRecordingId: UUID?
    private var levelTimer: Timer?
    /// Tracks whether the current pause came from the user tapping Pause
    /// vs from an iOS interruption (phone call, Siri, alarm). If the user
    /// paused, an incoming call followed by call-end should NOT auto-resume.
    private var pausedByUser = false
    /// UIKit background task we request during interruptions so iOS gives us
    /// a few extra seconds of guaranteed runtime instead of suspending us the
    /// moment the call audio takes over.
    private var interruptionTaskID: UIBackgroundTaskIdentifier = .invalid

    /// UserDefaults key for the in-progress recording marker. See
    /// `InProgressRecording` for why this exists.
    private static let inProgressKey = "AudioRecorder.inProgressRecording"

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    // MARK: - Recording lifecycle

    /// Returns the recording id so the caller can persist it to the DB.
    @discardableResult
    func start() throws -> UUID {
        guard !isRecording else {
            throw RecorderError.alreadyRecording
        }
        try requestMicPermission()

        let recordingId = UUID()
        let fileURL = Self.recordingsDirectory()
            .appendingPathComponent("\(recordingId.uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,                  // mono — half the file size, fine for speech
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64_000                // 64 kbps AAC ≈ 30MB/hour
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecorderError.failedToStart
        }

        self.recorder = recorder
        self.currentFileURL = fileURL
        self.currentRecordingId = recordingId
        self.isRecording = true
        self.isPaused = false
        self.elapsedSeconds = 0
        self.lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true

        startMetering()
        RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: 0, isPaused: false)
        // Persist a marker so we can recover this file if iOS kills the app
        // before the user manually stops the recording.
        let marker = InProgressRecording(id: recordingId, title: defaultTitle(), createdAt: Date())
        if let data = try? JSONEncoder().encode(marker) {
            UserDefaults.standard.set(data, forKey: Self.inProgressKey)
        }
        return recordingId
    }

    func pause() {
        guard isRecording, !isPaused, let recorder else { return }
        recorder.pause()
        isPaused = true
        pausedByUser = true
        RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: elapsedSeconds, isPaused: true)
    }

    func resume() {
        guard isRecording, isPaused, let recorder else { return }
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        if recorder.record() {
            isPaused = false
            pausedByUser = false
            RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: elapsedSeconds, isPaused: false)
        }
    }

    /// Stop and finalize. Returns a PendingRecording the caller can hand to UploadQueue.
    func stop() -> PendingRecording? {
        guard let recorder, let fileURL = currentFileURL, let id = currentRecordingId else {
            return nil
        }
        let duration = Int(recorder.currentTime)
        recorder.stop()
        finishCleanup()
        return PendingRecording(
            id: id,
            localFileURL: fileURL,
            durationSeconds: duration,
            title: defaultTitle(),
            createdAt: Date()
        )
    }

    /// Cancel mid-recording. Deletes the file. Concern #4.
    func discardCurrentRecording() {
        recorder?.stop()
        if let fileURL = currentFileURL {
            try? FileManager.default.removeItem(at: fileURL)
        }
        finishCleanup()
    }

    private func finishCleanup() {
        recorder = nil
        currentFileURL = nil
        currentRecordingId = nil
        isRecording = false
        isPaused = false
        pausedByUser = false
        elapsedSeconds = 0
        audioLevel = 0
        levelTimer?.invalidate()
        levelTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        RecordingNotificationManager.shared.clearRecordingStatus()
        // Clean stop — discard the in-progress marker so we don't try to
        // recover a file we already shipped through the queue.
        UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
        endInterruptionBackgroundTask()
    }

    // MARK: - Background task during interruptions

    /// Ask UIKit for a background task as soon as the audio session is taken
    /// away from us. iOS gives us ~30 seconds of guaranteed runtime, which
    /// shrinks the window in which it can decide to suspend then kill us.
    /// Doesn't save us from very long calls — orphan recovery on launch
    /// handles that case.
    private func beginInterruptionBackgroundTask() {
        guard interruptionTaskID == .invalid else { return }
        interruptionTaskID = UIApplication.shared.beginBackgroundTask(withName: "RecordingInterruption") { [weak self] in
            // Expiration handler: end the task to avoid being killed for
            // overstaying our welcome.
            self?.endInterruptionBackgroundTask()
        }
    }

    private func endInterruptionBackgroundTask() {
        guard interruptionTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(interruptionTaskID)
        interruptionTaskID = .invalid
    }

    // MARK: - Orphan recovery

    /// Called once at app launch. If there's an in-progress marker AND its
    /// M4A is still on disk, return a PendingRecording for it so the caller
    /// can enqueue an upload. Clears the marker either way.
    static func recoverOrphanedRecording() -> PendingRecording? {
        guard let data = UserDefaults.standard.data(forKey: inProgressKey),
              let marker = try? JSONDecoder().decode(InProgressRecording.self, from: data) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: inProgressKey)

        let fileURL = recordingsDirectory().appendingPathComponent("\(marker.id.uuidString).m4a")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        // Best-effort duration via AVURLAsset. If it can't read the (possibly
        // partial) file, fall back to a rough estimate from file size: at
        // 64kbps mono AAC this is ~8 KB/sec.
        var duration = 0
        let asset = AVURLAsset(url: fileURL)
        if asset.duration.value > 0 {
            duration = Int(CMTimeGetSeconds(asset.duration))
        } else if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int {
            duration = max(1, size / 8000)
        }
        return PendingRecording(
            id: marker.id,
            localFileURL: fileURL,
            durationSeconds: duration,
            title: marker.title,
            createdAt: marker.createdAt
        )
    }

    // MARK: - Metering / live timer

    /// The timer is driven by AVAudioRecorder.currentTime — NEVER a separate counter.
    /// This guarantees the UI timer can't disagree with what's actually on disk.
    /// (Concern #5: "recording in progress but timer at zero".)
    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                let normalized = max(0, (db + 60) / 60)
                self.audioLevel = normalized
                self.elapsedSeconds = recorder.currentTime
                // Update the Notification Center status (re-post is no-op
                // unless the body string actually changed; the manager handles
                // that so we don't spam the system).
                RecordingNotificationManager.shared.showRecordingStatus(
                    elapsedSeconds: self.elapsedSeconds,
                    isPaused: self.isPaused
                )
            }
        }
    }

    // MARK: - Permissions

    private func requestMicPermission() throws {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            return
        case .undetermined:
            // Trigger the prompt; the next call will succeed if user grants.
            AVAudioApplication.requestRecordPermission { _ in }
            throw RecorderError.permissionPrompted
        case .denied:
            throw RecorderError.permissionDenied
        @unknown default:
            throw RecorderError.permissionDenied
        }
    }

    // MARK: - Interruption handling (concern #8)

    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        switch type {
        case .began:
            isPaused = true
            // Beg iOS for a few more seconds of runtime in case the call drags
            // on. iOS gives us ~30s — better than nothing. For longer calls,
            // orphan recovery on next launch is the safety net.
            beginInterruptionBackgroundTask()
        case .ended:
            // Whether or not we auto-resume, end the background task — we
            // either get back to recording (mic keeps us alive) or stay paused
            // (no point holding the task).
            defer { endInterruptionBackgroundTask() }
            guard let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            guard opts.contains(.shouldResume),
                  !pausedByUser,
                  let recorder,
                  isRecording else { return }
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            if recorder.record() {
                isPaused = false
            }
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        // Headphone unplugged etc. We let AVFoundation handle routing automatically;
        // this hook is here so you can extend it later (e.g. auto-pause on Bluetooth disconnect).
    }

    // MARK: - Recovery on launch

    /// Returns any .m4a file in the recordings directory that isn't currently active.
    /// Use this on app launch to recover a recording the OS killed before stop() was called.
    static func orphanedFiles() -> [URL] {
        let dir = recordingsDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "m4a" }
    }

    static func recordingsDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("recordings", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Returns the on-disk URL for a recording's audio file, or nil if it isn't there.
    /// The file lives at recordingsDirectory()/<UUID-uppercase>.m4a.
    static func localAudioURL(for recordingId: UUID) -> URL? {
        let url = recordingsDirectory().appendingPathComponent("\(recordingId.uuidString).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete the local audio file for a recording. No-op if it doesn't exist.
    static func deleteLocalAudio(for recordingId: UUID) {
        let url = recordingsDirectory().appendingPathComponent("\(recordingId.uuidString).m4a")
        try? FileManager.default.removeItem(at: url)
    }

    private func defaultTitle() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, h:mm a"
        return f.string(from: Date())
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag { self.lastError = "Recording finished unsuccessfully" }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            self.lastError = error?.localizedDescription ?? "Encoder error"
        }
    }
}

enum RecorderError: LocalizedError {
    case alreadyRecording
    case failedToStart
    case permissionPrompted
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A recording is already in progress."
        case .failedToStart:    return "Failed to start recording. Try restarting the app."
        case .permissionPrompted: return "Please grant microphone access and tap Record again."
        case .permissionDenied: return "Microphone access is denied. Enable it in Settings → TranscriptionAPPMVP."
        }
    }
}
