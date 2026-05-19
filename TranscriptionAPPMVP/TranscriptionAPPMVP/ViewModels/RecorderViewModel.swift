import Foundation
import Combine

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var lastStoppedRecordingId: UUID?

    private let recorder = AudioRecorder.shared
    private let uploads = UploadQueue.shared
    private var cancellables = Set<AnyCancellable>()

    var isRecording: Bool { recorder.isRecording }
    var isPaused: Bool { recorder.isPaused }
    var isFinalizing: Bool { recorder.isFinalizing }
    var elapsedSeconds: TimeInterval { recorder.elapsedSeconds }
    var audioLevel: Float { recorder.audioLevel }
    var pendingOrphan: PendingRecording? { recorder.pendingOrphan }

    init() {
        recorder.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func startRecording() {
        do {
            _ = try recorder.start()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func togglePause() {
        if recorder.isPaused {
            recorder.resume()
        } else {
            recorder.pause()
        }
    }

    func stopAndUpload() {
        // Stop is async because it concatenates segment files into a single
        // M4A. While that runs, recorder.isFinalizing is true so the view
        // can show a "Saving…" state.
        Task { @MainActor in
            guard let pending = await recorder.stop() else { return }
            lastStoppedRecordingId = pending.id
            uploads.enqueue(pending)
        }
    }

    func discard() {
        recorder.discardCurrentRecording()
    }

    // MARK: - Orphan actions (resume / save / discard a recording that
    // survived iOS killing the app mid-session)

    func continueOrphan() {
        do {
            _ = try recorder.resumeOrphan()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveOrphan() {
        recorder.saveOrphanWithoutResume()
    }

    func discardOrphan() {
        recorder.discardOrphan()
    }
}
