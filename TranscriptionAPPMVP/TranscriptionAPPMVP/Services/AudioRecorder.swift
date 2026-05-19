import Foundation
import AVFoundation
import Combine
import UIKit

/// Singleton recorder. Enforces "only one recording session at a time" so two
/// taps on Record can't create two AVAudioRecorders fighting over the mic.
///
/// Architecture: a recording is a list of M4A *segment files*, not a single
/// file. Each segment is written end-to-end by a single AVAudioRecorder
/// instance (so the file stays valid). A new segment is started whenever the
/// recorder is paused or torn down — by the user, or by iOS during a phone
/// call, Siri, etc. On Stop, we concatenate all segments into the canonical
/// `<id>.m4a` that the rest of the app expects.
///
/// Why segments and not a single file with pause/resume on the same recorder:
/// AVAudioRecorder does NOT support appending to an existing file. Re-opening
/// an AVAudioRecorder on the same URL OVERWRITES it. So once iOS forces us to
/// rebuild the recorder (long calls, audio-session resets), we must write to a
/// new file or we lose everything captured before.
///
/// Concerns this satisfies:
/// - #2 "recording lost after pause/close": each pause/interruption closes its
///   segment cleanly on disk; partial recordings are recoverable via orphan
///   flow at next launch.
/// - #4 "no way to delete a bad recording mid-session": `discardCurrentRecording()`.
/// - #5 "recording in progress but timer at zero": the displayed timer derives
///   from `elapsedBeforeCurrentSegment + recorder.currentTime`, so it survives
///   iOS rotating the record session around an interruption.
/// - #6 "two recording sessions cancel each other out": single shared instance
///   plus the `isRecording` guard.
/// - #8 "switching apps fails the recording": interruption handler closes
///   the live segment cleanly and stays paused. The user resumes
///   explicitly — a phone call shouldn't silently re-arm the mic.
@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    static let shared = AudioRecorder()

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    /// True while `stop()` is concatenating segments. The UI shows a "Saving…"
    /// indicator instead of the normal recording controls during this window.
    @Published private(set) var isFinalizing = false
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0          // 0…1, for the waveform UI
    @Published private(set) var lastError: String?
    /// If iOS killed the app mid-recording and segment files are still on disk,
    /// this is set on app launch so the UI can offer Continue / Save / Discard.
    /// Nil otherwise.
    @Published var pendingOrphan: PendingRecording?

    private var recorder: AVAudioRecorder?
    private var currentFileURL: URL?
    private var currentRecordingId: UUID?
    private var levelTimer: Timer?
    /// Tracks whether the current pause came from the user tapping Pause
    /// vs from an iOS interruption (phone call, Siri, alarm). If the user
    /// paused, an incoming call followed by call-end should NOT auto-resume.
    private var pausedByUser = false

    /// URLs of segment files that have been fully written and closed. Live
    /// segment (if recording) is `currentFileURL` — that one is in flight
    /// and not yet finalized.
    private var segmentURLs: [URL] = []
    /// Sum of all closed-segment durations, in seconds. The displayed timer
    /// is `elapsedBeforeCurrentSegment + (live segment progress)`.
    private var elapsedBeforeCurrentSegment: TimeInterval = 0
    /// Largest `recorder.currentTime` we've observed in the current live
    /// segment. Monotonic — we never let the displayed timer go backwards.
    private var maxCurrentTimeInSegment: TimeInterval = 0

    /// UIKit background task we request during interruptions so iOS gives us
    /// a few extra seconds of guaranteed runtime instead of suspending us the
    /// moment the call audio takes over.
    private var interruptionTaskID: UIBackgroundTaskIdentifier = .invalid

    /// UserDefaults key for the in-progress recording marker. See
    /// `InProgressRecording` for why this exists.
    private static let inProgressKey = "AudioRecorder.inProgressRecording"

    /// Encoder settings shared by every segment. Must stay identical across
    /// segments so the final concatenated M4A has a consistent format.
    private static let recorderSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,                  // mono — half the file size, fine for speech
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        AVEncoderBitRateKey: 64_000                // 64 kbps AAC ≈ 30MB/hour
    ]

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
        self.currentRecordingId = recordingId
        self.segmentURLs = []
        self.elapsedBeforeCurrentSegment = 0
        self.maxCurrentTimeInSegment = 0
        self.elapsedSeconds = 0

        guard startNewSegment() else {
            self.currentRecordingId = nil
            throw RecorderError.failedToStart
        }

        self.isRecording = true
        self.isPaused = false
        self.pausedByUser = false
        self.lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true

        startMetering()
        RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: 0, isPaused: false)
        // Persist a marker so we can recover the segment files if iOS kills
        // the app before the user manually stops the recording.
        let marker = InProgressRecording(id: recordingId, title: defaultTitle(), createdAt: Date())
        if let data = try? JSONEncoder().encode(marker) {
            UserDefaults.standard.set(data, forKey: Self.inProgressKey)
        }
        return recordingId
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        closeCurrentSegment()
        isPaused = true
        pausedByUser = true
        RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: elapsedSeconds, isPaused: true)
    }

    func resume() {
        guard isRecording, isPaused else { return }
        try? AVAudioSession.sharedInstance().setActive(true, options: [])
        if startNewSegment() {
            isPaused = false
            pausedByUser = false
            RecordingNotificationManager.shared.showRecordingStatus(elapsedSeconds: elapsedSeconds, isPaused: false)
        } else {
            lastError = "Couldn't resume after pause. Tap Stop & Save to keep what's recorded."
        }
    }

    /// Stop and finalize. Concatenates all segment files into the canonical
    /// `<id>.m4a` the rest of the app reads. Returns a PendingRecording the
    /// caller hands to UploadQueue.
    func stop() async -> PendingRecording? {
        guard let id = currentRecordingId else { return nil }

        // Close the live segment if there is one — captures the final bit of
        // audio that hasn't been rolled into segmentURLs yet.
        closeCurrentSegment()

        // segmentURLs now holds every M4A piece we wrote, in record order.
        let segments = segmentURLs
        let totalDuration = Int(elapsedBeforeCurrentSegment)
        guard !segments.isEmpty else {
            // Nothing was recorded (e.g. start() succeeded but no audio).
            finishCleanup()
            return nil
        }

        isFinalizing = true
        let finalURL = Self.recordingsDirectory().appendingPathComponent("\(id.uuidString).m4a")
        try? FileManager.default.removeItem(at: finalURL)

        let finalizedURL: URL?
        do {
            if segments.count == 1 {
                // Single segment — just rename it to the canonical name.
                try FileManager.default.moveItem(at: segments[0], to: finalURL)
                finalizedURL = finalURL
            } else {
                try await Self.concatenateM4A(segments, to: finalURL)
                for url in segments {
                    try? FileManager.default.removeItem(at: url)
                }
                finalizedURL = finalURL
            }
        } catch {
            lastError = "Couldn't save the recording: \(error.localizedDescription)"
            finalizedURL = nil
        }

        isFinalizing = false

        guard let outputURL = finalizedURL else {
            // Leave segments on disk so a future build could recover them.
            finishCleanup()
            return nil
        }

        let pending = PendingRecording(
            id: id,
            localFileURL: outputURL,
            durationSeconds: totalDuration,
            title: defaultTitle(),
            createdAt: Date()
        )
        finishCleanup()
        return pending
    }

    /// Cancel mid-recording. Deletes every segment file. Concern #4.
    func discardCurrentRecording() {
        recorder?.stop()
        // Live segment (in flight)
        if let url = currentFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        // Closed segments
        for url in segmentURLs {
            try? FileManager.default.removeItem(at: url)
        }
        finishCleanup()
    }

    // MARK: - Segment plumbing

    /// Build the URL for the Nth segment of a given recording id.
    private static func segmentURL(for id: UUID, index: Int) -> URL {
        recordingsDirectory()
            .appendingPathComponent("\(id.uuidString)_seg\(index).m4a")
    }

    /// Construct a fresh AVAudioRecorder pointed at a new segment URL and
    /// start it. Returns false if anything goes wrong; in that case the
    /// recorder and currentFileURL are left untouched so the caller can
    /// surface an error without losing state.
    private func startNewSegment() -> Bool {
        guard let id = currentRecordingId else { return false }
        let url = Self.segmentURL(for: id, index: segmentURLs.count)
        do {
            let r = try AVAudioRecorder(url: url, settings: Self.recorderSettings)
            r.delegate = self
            r.isMeteringEnabled = true
            guard r.prepareToRecord(), r.record() else { return false }
            self.recorder = r
            self.currentFileURL = url
            self.maxCurrentTimeInSegment = 0
            return true
        } catch {
            self.lastError = "Couldn't open audio file: \(error.localizedDescription)"
            return false
        }
    }

    /// Stop the live recorder, finalize its file on disk, push it into
    /// `segmentURLs`, and roll its duration into the accumulator. Called from
    /// every code path that ends a segment: user pause, iOS interruption,
    /// stop & save.
    private func closeCurrentSegment() {
        guard let r = recorder, let url = currentFileURL else { return }
        let ct = r.currentTime
        maxCurrentTimeInSegment = max(maxCurrentTimeInSegment, ct)
        r.stop()
        segmentURLs.append(url)
        elapsedBeforeCurrentSegment += maxCurrentTimeInSegment
        maxCurrentTimeInSegment = 0
        elapsedSeconds = elapsedBeforeCurrentSegment
        self.recorder = nil
        self.currentFileURL = nil
    }

    /// Concatenate M4A segments into a single M4A using AVMutableComposition
    /// + AVAssetExportSession. AAC re-mux is fast (no re-encode), so this
    /// runs in seconds even for long recordings.
    private static func concatenateM4A(_ urls: [URL], to outputURL: URL) async throws {
        let composition = AVMutableComposition()
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw NSError(domain: "AudioRecorder", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create audio composition track"
            ])
        }

        var insertAt = CMTime.zero
        for url in urls {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks.first else { continue }
            let duration = try await asset.load(.duration)
            guard CMTimeGetSeconds(duration).isFinite, CMTimeGetSeconds(duration) > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            try audioTrack.insertTimeRange(range, of: track, at: insertAt)
            insertAt = CMTimeAdd(insertAt, duration)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw NSError(domain: "AudioRecorder", code: 101, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't create export session"
            ])
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume() }
        }

        if exporter.status != .completed {
            throw exporter.error ?? NSError(domain: "AudioRecorder", code: 102, userInfo: [
                NSLocalizedDescriptionKey: "Audio export failed"
            ])
        }
    }

    /// Sum the durations of a list of M4A files (no async load — used in
    /// orphan recovery on launch where we need a quick estimate).
    private static func totalDuration(of urls: [URL]) -> TimeInterval {
        var total: TimeInterval = 0
        for url in urls {
            let asset = AVURLAsset(url: url)
            let s = CMTimeGetSeconds(asset.duration)
            if s.isFinite, s > 0 { total += s }
        }
        return total
    }

    private func finishCleanup() {
        recorder = nil
        currentFileURL = nil
        currentRecordingId = nil
        segmentURLs = []
        isRecording = false
        isPaused = false
        pausedByUser = false
        elapsedSeconds = 0
        elapsedBeforeCurrentSegment = 0
        maxCurrentTimeInSegment = 0
        audioLevel = 0
        levelTimer?.invalidate()
        levelTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        RecordingNotificationManager.shared.clearRecordingStatus()
        // Clean stop — discard the in-progress marker so we don't try to
        // recover a recording we already shipped through the queue.
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
            self?.endInterruptionBackgroundTask()
        }
    }

    private func endInterruptionBackgroundTask() {
        guard interruptionTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(interruptionTaskID)
        interruptionTaskID = .invalid
    }

    // MARK: - Orphan recovery (Continue / Save / Discard)

    /// Called at app launch. If the in-progress marker plus any segment files
    /// exist, surface them as `pendingOrphan` for the UI to handle. Does NOT
    /// clear the marker — that happens once the user picks an action.
    func checkForOrphan() {
        guard let data = UserDefaults.standard.data(forKey: Self.inProgressKey),
              let marker = try? JSONDecoder().decode(InProgressRecording.self, from: data) else {
            return
        }
        let segs = orphanSegmentFiles(for: marker.id)
        // Backward compat: an older build might have left a single
        // `<id>.m4a` (no _seg suffix). Treat it as the first segment.
        let legacyURL = Self.recordingsDirectory().appendingPathComponent("\(marker.id.uuidString).m4a")
        let hasLegacy = segs.isEmpty && FileManager.default.fileExists(atPath: legacyURL.path)
        guard !segs.isEmpty || hasLegacy else {
            UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
            return
        }
        let files = hasLegacy ? [legacyURL] : segs
        let duration = max(1, Int(Self.totalDuration(of: files)))
        pendingOrphan = PendingRecording(
            id: marker.id,
            // Placeholder; orphan UI only reads id + duration + title.
            localFileURL: files[0],
            durationSeconds: duration,
            title: marker.title,
            createdAt: marker.createdAt
        )
    }

    /// Continue an orphan: keep its existing segment files and start a new
    /// segment for the live audio. The Stop action will concatenate
    /// everything into a single M4A.
    @discardableResult
    func resumeOrphan() throws -> UUID {
        guard !isRecording else { throw RecorderError.alreadyRecording }
        guard let orphan = pendingOrphan else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No pending recording to continue."
            ])
        }
        try requestMicPermission()

        var existing = orphanSegmentFiles(for: orphan.id)
        // Migrate legacy single-file recordings into seg0 so the new pipeline
        // can append more segments cleanly.
        if existing.isEmpty {
            let legacy = Self.recordingsDirectory().appendingPathComponent("\(orphan.id.uuidString).m4a")
            if FileManager.default.fileExists(atPath: legacy.path) {
                let seg0 = Self.segmentURL(for: orphan.id, index: 0)
                try? FileManager.default.moveItem(at: legacy, to: seg0)
                existing = [seg0]
            }
        }
        guard !existing.isEmpty else {
            pendingOrphan = nil
            UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The previous recording's files are missing."
            ])
        }

        try? AVAudioSession.sharedInstance().setActive(true, options: [])

        self.currentRecordingId = orphan.id
        self.segmentURLs = existing
        self.elapsedBeforeCurrentSegment = Self.totalDuration(of: existing)
        self.maxCurrentTimeInSegment = 0
        self.elapsedSeconds = self.elapsedBeforeCurrentSegment
        self.isRecording = true
        self.isPaused = false
        self.pausedByUser = false
        self.lastError = nil

        guard startNewSegment() else {
            // Roll back to a paused state so the user can Stop & Save what
            // they have rather than losing the orphan entirely.
            self.isPaused = true
            self.lastError = "Couldn't reopen the audio file."
            return orphan.id
        }

        UIApplication.shared.isIdleTimerDisabled = true
        startMetering()
        RecordingNotificationManager.shared.showRecordingStatus(
            elapsedSeconds: elapsedSeconds, isPaused: false
        )
        pendingOrphan = nil
        return orphan.id
    }

    /// Save an orphan as-is (no live continuation): concatenate the existing
    /// segments into the canonical `<id>.m4a` and enqueue for upload.
    func saveOrphanWithoutResume() {
        guard let orphan = pendingOrphan else { return }
        pendingOrphan = nil
        Task { @MainActor in
            await self.finalizeOrphanForUpload(orphan: orphan)
        }
    }

    private func finalizeOrphanForUpload(orphan: PendingRecording) async {
        let segs = orphanSegmentFiles(for: orphan.id)
        let legacy = Self.recordingsDirectory().appendingPathComponent("\(orphan.id.uuidString).m4a")
        let hasLegacy = segs.isEmpty && FileManager.default.fileExists(atPath: legacy.path)
        let finalURL = legacy   // canonical destination
        do {
            if !segs.isEmpty {
                try? FileManager.default.removeItem(at: finalURL)
                if segs.count == 1 {
                    try FileManager.default.moveItem(at: segs[0], to: finalURL)
                } else {
                    try await Self.concatenateM4A(segs, to: finalURL)
                    for url in segs { try? FileManager.default.removeItem(at: url) }
                }
            } else if !hasLegacy {
                // Nothing to save.
                UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
                return
            }
            let duration = max(1, Int(Self.totalDuration(of: [finalURL])))
            let pending = PendingRecording(
                id: orphan.id,
                localFileURL: finalURL,
                durationSeconds: duration,
                title: orphan.title,
                createdAt: orphan.createdAt
            )
            UploadQueue.shared.enqueue(pending)
            UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
        } catch {
            self.lastError = "Couldn't save the previous recording: \(error.localizedDescription)"
        }
    }

    /// Discard an orphan: delete every segment file (and the legacy single
    /// file, if present), clear the marker, forget the orphan.
    func discardOrphan() {
        guard let orphan = pendingOrphan else { return }
        for url in orphanSegmentFiles(for: orphan.id) {
            try? FileManager.default.removeItem(at: url)
        }
        let legacy = Self.recordingsDirectory().appendingPathComponent("\(orphan.id.uuidString).m4a")
        try? FileManager.default.removeItem(at: legacy)
        UserDefaults.standard.removeObject(forKey: Self.inProgressKey)
        pendingOrphan = nil
    }

    /// List `<id>_seg*.m4a` files for a recording id, sorted by name so the
    /// segment order matches recording order.
    private func orphanSegmentFiles(for id: UUID) -> [URL] {
        let dir = Self.recordingsDirectory()
        let prefix = "\(id.uuidString)_seg"
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "m4a" }
            .sorted { lhs, rhs in
                // Compare by numeric index so seg10 sorts after seg2.
                let li = Self.segmentIndex(from: lhs)
                let ri = Self.segmentIndex(from: rhs)
                return li < ri
            }
    }

    private static func segmentIndex(from url: URL) -> Int {
        // Filename pattern: <UUID>_seg<N>.m4a
        let name = url.deletingPathExtension().lastPathComponent
        guard let r = name.range(of: "_seg") else { return Int.max }
        return Int(name[r.upperBound...]) ?? Int.max
    }

    // MARK: - Metering / live timer

    /// Displayed timer = sum of finalized segments + the live segment's
    /// progress. AVAudioRecorder.currentTime is monotonic within a segment;
    /// closing a segment rolls its peak into the accumulator. (Concern #5.)
    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                let db = recorder.averagePower(forChannel: 0)
                let normalized = max(0, (db + 60) / 60)
                self.audioLevel = normalized

                let ct = recorder.currentTime
                self.maxCurrentTimeInSegment = max(self.maxCurrentTimeInSegment, ct)
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
            // Close the live segment so its M4A is finalized on disk before
            // iOS can suspend us. We'll start a brand-new segment file on
            // resume — that's the only way to preserve pre-call audio,
            // because re-opening AVAudioRecorder on the same URL overwrites
            // it rather than appending.
            closeCurrentSegment()
            isPaused = true
            // Beg iOS for a few more seconds of runtime in case the call drags
            // on. iOS gives us ~30s — better than nothing. For longer calls,
            // orphan recovery on next launch is the safety net.
            beginInterruptionBackgroundTask()
        case .ended:
            // Deliberately do NOT auto-resume the recording. After a call the
            // user may have walked away, switched contexts, or wants to wrap
            // up — silently picking the mic back up surprises people. We
            // stay paused and surface Resume / Stop & Save / Discard in the
            // UI so resuming is an explicit choice.
            endInterruptionBackgroundTask()
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        // Headphone unplugged etc. We let AVFoundation handle routing automatically;
        // this hook is here so you can extend it later (e.g. auto-pause on Bluetooth disconnect).
    }

    // MARK: - Recovery on launch / file lookup

    /// Returns any .m4a file in the recordings directory. Used by ad-hoc
    /// cleanup tools, not the main orphan recovery path.
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
    /// The canonical post-stop file lives at recordingsDirectory()/<UUID>.m4a.
    static func localAudioURL(for recordingId: UUID) -> URL? {
        let url = recordingsDirectory().appendingPathComponent("\(recordingId.uuidString).m4a")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Delete the local audio file for a recording. No-op if it doesn't exist.
    /// Also sweeps any leftover segment files for the same id so a deleted
    /// recording doesn't leave fragments behind.
    static func deleteLocalAudio(for recordingId: UUID) {
        let dir = recordingsDirectory()
        let canonical = dir.appendingPathComponent("\(recordingId.uuidString).m4a")
        try? FileManager.default.removeItem(at: canonical)
        let prefix = "\(recordingId.uuidString)_seg"
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: f)
            }
        }
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
