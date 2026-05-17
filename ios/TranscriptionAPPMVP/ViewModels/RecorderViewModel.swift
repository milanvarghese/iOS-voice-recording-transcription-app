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
    var elapsedSeconds: TimeInterval { recorder.elapsedSeconds }
    var audioLevel: Float { recorder.audioLevel }

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
        guard let pending = recorder.stop() else { return }
        lastStoppedRecordingId = pending.id
        uploads.enqueue(pending)
    }

    func discard() {
        recorder.discardCurrentRecording()
    }
}
