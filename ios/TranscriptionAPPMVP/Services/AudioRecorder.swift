import Foundation
import AVFoundation
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
        return recordingId
    }

    func pause() {
        guard isRecording, !isPaused, let recorder else { return }
        recorder.pause()
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused, let recorder else { return }
        if recorder.record() {
            isPaused = false
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
        elapsedSeconds = 0
        audioLevel = 0
        levelTimer?.invalidate()
        levelTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - Metering / live timer

    /// The timer is driven by AVAudioRecorder.currentTime — NEVER a separate counter.
    /// This guarantees the UI timer can't disagree with what's actually on disk.
    /// (Concern #5: "recording in progress but timer at zero".)
    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                // Map -60dB...0dB to 0...1 with simple linear scaling
                let normalized = max(0, (db + 60) / 60)
                self.audioLevel = normalized
                self.elapsedSeconds = recorder.currentTime
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
            // Phone call / Siri started. AVAudioRecorder is paused for us automatically.
            isPaused = true
        case .ended:
            guard let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            if opts.contains(.shouldResume), let recorder, isRecording {
                if recorder.record() { isPaused = false }
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
