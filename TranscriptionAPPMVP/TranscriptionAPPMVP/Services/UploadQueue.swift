import Combine
import Foundation

/// A persistent FIFO queue of pending uploads.
///
/// Why this exists separately from AudioRecorder:
///   - "A failed upload blocks all new recordings" (concern #3) — the recorder must
///     not be coupled to the upload. The queue runs independently. New recordings
///     can always start, even if the queue has a stuck item.
///   - "Upload fails silently" (concern #7) — every item has an explicit state
///     (.pending, .uploading, .failed) shown in the UI.
///   - "Switching apps fails the recording" (concern #8) — uploads continue when
///     the app is backgrounded because they run as Task-detached work; if the OS
///     suspends the app, the queue is persisted to disk and resumed on next launch.
///   - Resilience to a kill-during-upload: queue lives in UserDefaults, files
///     stay on disk, retry on next launch.
@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    @Published private(set) var queue: [PendingRecording] = []
    @Published private(set) var currentItemId: UUID?
    @Published private(set) var lastError: String?

    private let storageKey = "UploadQueue.pending"
    private var isProcessing = false

    private init() {
        loadFromDisk()
        // Resume any work left over from a previous launch.
        Task { await processNext() }
    }

    func enqueue(_ pending: PendingRecording) {
        queue.append(pending)
        saveToDisk()
        Task { await processNext() }
    }

    func remove(id: UUID) {
        queue.removeAll { $0.id == id }
        saveToDisk()
    }

    // MARK: - Processing

    private func processNext() async {
        guard !isProcessing, let item = queue.first else { return }
        isProcessing = true
        currentItemId = item.id
        defer {
            isProcessing = false
            currentItemId = nil
        }

        do {
            try await upload(item)
            queue.removeFirst()
            saveToDisk()
            await processNext()
        } catch {
            lastError = error.localizedDescription
            // Pop the failed item so the queue can move on. The recording stays
            // in History marked .failed; user can delete or re-upload from there.
            queue.removeFirst()
            saveToDisk()
            try? await SupabaseService.shared.updateRecording(
                id: item.id,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            await processNext()
        }
    }

    private func upload(_ item: PendingRecording) async throws {
        guard let userId = SupabaseService.shared.currentUserId else {
            throw NSError(domain: "UploadQueue", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Signed out"
            ])
        }

        // Storage RLS compares the first folder name (text) against auth.uid()::text,
        // which Postgres formats as lowercase. Swift's UUID.uuidString defaults to
        // uppercase, so we lowercase here or RLS rejects the upload.
        let storagePath = "\(userId.uuidString.lowercased())/\(item.id.uuidString.lowercased()).m4a"

        // 1. Insert the placeholder row (idempotent — we use the local id).
        let recording = Recording(
            id: item.id,
            userId: userId,
            title: item.title,
            durationSeconds: item.durationSeconds,
            status: .uploading,
            storagePath: nil,
            assemblyaiId: nil,
            transcript: nil,
            errorMessage: nil,
            createdAt: item.createdAt,
            updatedAt: item.createdAt
        )
        try? await SupabaseService.shared.insertRecording(recording)  // ok if duplicate

        try await SupabaseService.shared.updateRecording(
            id: item.id, status: .uploading
        )

        // 2. Upload the audio file.
        try await SupabaseService.shared.uploadAudio(
            localURL: item.localFileURL,
            storagePath: storagePath
        )

        // 3. Mark uploaded.
        try await SupabaseService.shared.updateRecording(
            id: item.id,
            status: .uploaded,
            storagePath: storagePath,
            durationSeconds: item.durationSeconds
        )

        // 4. Hand off to the transcription Edge Function. If this fails, the
        //    row stays in .uploaded and we surface a retry button in the UI.
        try await SupabaseService.shared.submitForTranscription(recordingId: item.id)

        try await SupabaseService.shared.updateRecording(
            id: item.id, status: .transcribing
        )

        // Keep the local file. The user can play it back instantly without
        // re-downloading, and it stays on the phone until they swipe-delete
        // the recording in History (HistoryViewModel.delete also removes it).
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([PendingRecording].self, from: data)
        else { return }
        self.queue = decoded
    }

    private func saveToDisk() {
        let data = try? JSONEncoder().encode(queue)
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
