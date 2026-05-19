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
///    (concern #2). The displayed timer is derived from
///    `recorder.currentTime` plus a `elapsedBeforeCurrentSegment` accumulator,
///    because currentTime resets to 0 whenever iOS rotates the record session
///    around an interruption (concern #5, "recording in progress but timer at zero").
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
    /// If iOS killed the app mid-recording and the M4A is still on disk,
    /// this is set on app launch so the UI can offer Continue / Save /
    /// Discard. Nil otherwise.
    @Published var pendingOrphan: PendingRecording?

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var currentRecordingId: UUID?
    private var levelTimer: Timer?
    /// Tracks whether the current pause came from the user tapping Pause
    /// vs from an iOS interruption (phone call, Siri, alarm). If the user
    /// paused, an incoming call followed by call-end should NOT auto-resume.
    private var pausedByUser = false

    // MARK: - Segmented duration accounting
    //
    // AVAudioRecorder.currentTime reports the position within the *current
    // record segment*, not the total file duration. When iOS interrupts the
    // recorder (phone call), the segment effectively ends; calling record()
    // again starts a fresh segment at 0 — but the M4A on disk keeps being
    // appended to, so file duration > currentTime. Without bookkeeping the
    // visible timer would reset to 00:00 after every call interruption even
    // though the recording itself is fine.
    //
    // elapsedBeforeCurrentSegment: sum of all completed segments' durations
    // maxCurrentTimeInSegment:     largest currentTime we've observed in
    //                              the live segment (monotonic — we never
    //                              show the clock running backwards)
    // displayed elapsedSeconds = elapsedBeforeCurrentSegment + maxCurrentTimeInSegment
    //
    // When the metering tick sees currentTime jump backwards (typical sign
    // of a new segment after an iOS interruption), we roll
    // maxCurrentTimeInSegment into elapsedBeforeCurrentSegment and reset the
    // segment-max to the new value.
    private var elapsedBeforeCurrentSegment: TimeInterval = 0
    private var maxCurrentTimeInSegment: TimeInterval = 0
    /// UIKit background task we request during interruptions so iOS gives us
    /// a few extra seconds of guaranteed runtime instead of suspending us the
    /// moment the call audio takes over.
    private var interruptionTaskID: UIBackgroundTaskIdentifier = .invalid
    /// True after handleInterruption(.began) has stopped the current
    /// AVAudioRecorder. The instance can't be safely reused — resume must
    /// create a NEW AVAudioRecorder on the same URL (which appends to the
    /// existing M4A).
    private var needsRecorderRecreation = false

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
        self.elapsedBeforeCurrentSegment = 0
        self.maxCurrentTimeInSegment = 0
        self.needsRecorderRecreation = false
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
        // Freeze the displayed elapsed time at the moment of pause so the UI
        // doesn't jitter if AVAudioRecorder.currentTime starts reporting 0
        // while paused on some iOS versions.
        let ct = recorder.currentTime
        maxCurrentTimeInSegment = max(maxCurrentTimeInSegment, ct)
        elapsedSeconds = elapsedBeforeCurrentSegment + maxCurrentTimeInSegment
        recorder.pause()
        isPaused = true
        pausedByUser = true
        RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: elapsedSeconds, isPaused: true)
    }

    func resume() {
        guard isRecording, isPaused else { return }
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        // If the previous recorder was torn down by an interruption, we
        // must reopen the file with a fresh AVAudioRecorder — reusing the
        // old instance can overwrite the M4A's existing audio.
        if needsRecorderRecreation {
            if recreateRecorderForAppend() {
                isPaused = false
                pausedByUser = false
                needsRecorderRecreation = false
                RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: elapsedSeconds, isPaused: false)
            } else {
                lastError = "Could not resume after interruption. Stop & Save to keep what's recorded so far."
            }
            return
        }
        guard let recorder else { return }
        if recorder.record() {
            isPaused = false
            pausedByUser = false
            RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: elapsedSeconds, isPaused: false)
        }
    }

    /// Constructs a brand-new AVAudioRecorder on the existing currentFileURL
    /// and starts recording. Because the URL already has audio, AVAudioRecorder
    /// appends — this is the same trick `resumeOrphan` uses, generalized to
    /// the mid-session interruption case. Returns false on any failure.
    private func recreateRecorderForAppend() -> Bool {
        guard let fileURL = currentFileURL else { return false }
        // Encoder settings must match start() exactly — AVAudioRecorder
        // refuses to append onto a file whose format doesn't line up.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64_000
        ]
        guard let newRecorder = try? AVAudioRecorder(url: fileURL, settings: settings) else {
            return false
        }
        newRecorder.delegate = self
        newRecorder.isMeteringEnabled = true
        guard newRecorder.prepareToRecord(), newRecorder.record() else {
            return false
        }
        self.recorder = newRecorder
        // Live segment starts at 0 again; the accumulator already holds the
        // pre-interruption duration thanks to handleInterruption(.began).
        self.maxCurrentTimeInSegment = 0
        return true
    }

    /// Stop and finalize. Returns a PendingRecording the caller can hand to UploadQueue.
    /// Works whether or not we currently have an AVAudioRecorder: during a
    /// phone-call interruption the recorder is torn down, but the M4A on disk
    /// is still valid and `elapsedBeforeCurrentSegment` already holds the
    /// captured duration, so the user can Stop & Save what they have.
    func stop() -> PendingRecording? {
        guard let fileURL = currentFileURL, let id = currentRecordingId else {
            return nil
        }
        let segmentDuration: TimeInterval
        if let recorder {
            segmentDuration = max(maxCurrentTimeInSegment, recorder.currentTime)
            recorder.stop()
        } else {
            segmentDuration = maxCurrentTimeInSegment
        }
        let duration = Int(elapsedBeforeCurrentSegment + segmentDuration)
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
        elapsedBeforeCurrentSegment = 0
        maxCurrentTimeInSegment = 0
        needsRecorderRecreation = false
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

    // MARK: - Orphan recovery (Continue / Save / Discard)

    /// Called at app launch. If there's an in-progress marker AND its M4A is
    /// still on disk, surface it as `pendingOrphan` for the UI to handle.
    /// Does NOT clear the marker — that happens when the user chooses an
    /// action (resumeOrphan / saveOrphanWithoutResume / discardOrphan).
    func checkForOrphan() {
        guard let data = UserDefaults.standard.data(forKey: Self.inProgressKey),
              let marker = try? JSONDecoder().decode(InProgressRecording.self, from: data) else {
            return
        }
        let fileURL = Self.recordingsDirectory().appendingPathComponent("\(marker.id.uuidString).m4a")
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // Marker without file — stale. Clean up so we don't keep checking.
            UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
            return
        }
        var duration = 0
        let asset = AVURLAsset(url: fileURL)
        if asset.duration.value > 0 {
            duration = Int(CMTimeGetSeconds(asset.duration))
        } else if let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.size] as? Int {
            duration = max(1, size / 8000)
        }
        pendingOrphan = PendingRecording(
            id: marker.id,
            localFileURL: fileURL,
            durationSeconds: duration,
            title: marker.title,
            createdAt: marker.createdAt
        )
    }

    /// User tapped Continue: reopen the orphan's M4A and append. AVAudioRecorder
    /// resumes from the end of the existing file when you call record() on a
    /// recorder initialized at the same URL with the same settings.
    @discardableResult
    func resumeOrphan() throws -> UUID {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        guard let orphan = pendingOrphan else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No pending recording to continue."
            ])
        }
        try requestMicPermission()
        let fileURL = orphan.localFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            pendingOrphan = nil
            UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The previous recording's file is missing."
            ])
        }

        // Same encoder settings as start() — required for AVAudioRecorder to
        // append cleanly. If these ever change, old orphans become unappendable.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64_000
        ]
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw RecorderError.failedToStart
        }

        self.recorder = recorder
        self.currentFileURL = fileURL
        self.currentRecordingId = orphan.id
        self.isRecording = true
        self.isPaused = false
        self.pausedByUser = false
        // Seed the accumulator with the existing M4A's duration so the timer
        // resumes from where the interrupted recording left off rather than
        // starting back at 00:00.
        let existingDuration: TimeInterval = {
            let asset = AVURLAsset(url: fileURL)
            let seconds = CMTimeGetSeconds(asset.duration)
            return seconds.isFinite && seconds > 0 ? seconds : TimeInterval(orphan.durationSeconds)
        }()
        self.elapsedBeforeCurrentSegment = existingDuration
        self.maxCurrentTimeInSegment = 0
        self.needsRecorderRecreation = false
        self.elapsedSeconds = existingDuration
        self.lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true

        // The in-progress marker is the same orphan's marker, so we leave it
        // in place — if iOS kills us again, the next launch finds the same
        // marker pointing at the same (now longer) file.

        startMetering()
        RecordingNotificationManager.shared.showRecordingStatus(
            elapsedSeconds: elapsedSeconds, isPaused: false
        )
        pendingOrphan = nil
        return orphan.id
    }

    /// User tapped Save: enqueue the orphan for upload as-is. This was the
    /// previous auto-recovery behavior, now opt-in.
    func saveOrphanWithoutResume() {
        guard let orphan = pendingOrphan else { return }
        UploadQueue.shared.enqueue(orphan)
        UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
        pendingOrphan = nil
    }

    /// User tapped Discard: delete the M4A and forget the orphan. Irreversible.
    func discardOrphan() {
        guard let orphan = pendingOrphan else { return }
        try? FileManager.default.removeItem(at: orphan.localFileURL)
        UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
        pendingOrphan = nil
    }

    // MARK: - Metering / live timer

    /// The displayed timer is derived from AVAudioRecorder.currentTime so it
    /// can't drift from what's actually on disk — but currentTime resets to
    /// 0 every time iOS starts a new record segment (notably after a phone
    /// call interruption). We accumulate completed segments into
    /// elapsedBeforeCurrentSegment and only ever show a monotonic clock.
    /// (Concern #5: "recording in progress but timer at zero".)
    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                let normalized = max(0, (db + 60) / 60)
                self.audioLevel = normalized

                let ct = recorder.currentTime
                // A rewind by >0.3s means AVAudioRecorder rotated into a new
                // segment (typical after an iOS-initiated pause/resume around
                // a phone call). Roll the previous segment's peak into the
                // accumulator and start measuring the new segment from ct.
                if ct + 0.3 < self.maxCurrentTimeInSegment {
                    self.elapsedBeforeCurrentSegment += self.maxCurrentTimeInSegment
                    self.maxCurrentTimeInSegment = ct
                } else {
                    self.maxCurrentTimeInSegment = max(self.maxCurrentTimeInSegment, ct)
                }
                self.elapsedSeconds = self.elapsedBeforeCurrentSegment + self.maxCurrentTimeInSegment
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
            // Snapshot the segment progress NOW, before iOS yanks the audio
            // session — once that happens, currentTime starts returning 0 and
            // we'd lose the live segment's contribution to the displayed
            // timer.
            if let r = recorder {
                let ct = r.currentTime
                maxCurrentTimeInSegment = max(maxCurrentTimeInSegment, ct)
                // Finalize the M4A on disk and roll the segment into the
                // accumulator. We drop the AVAudioRecorder instance entirely;
                // reusing it after iOS has taken the audio session away can
                // overwrite the existing audio when record() is called again,
                // which is the data-loss path the user kept hitting on calls.
                r.stop()
                elapsedBeforeCurrentSegment += maxCurrentTimeInSegment
                maxCurrentTimeInSegment = 0
                elapsedSeconds = elapsedBeforeCurrentSegment
            }
            recorder = nil
            needsRecorderRecreation = true
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
                  isRecording else { return }
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            // Build a fresh recorder on the same URL — appends to the M4A,
            // preserving everything captured before the call.
            if needsRecorderRecreation, recreateRecorderForAppend() {
                isPaused = false
                needsRecorderRecreation = false
            } else if let recorder, recorder.record() {
                // Defensive: if .began somehow didn't run (rare), fall back
                // to plain pause/resume semantics on the existing recorder.
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
