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
            // Process the next item, if any.
            await processNext()
        } catch {
            lastError = error.localizedDescription
            // Mark the recording row as failed so the user sees it in History
            // and can retry/delete. We do NOT remove the file — the user might
            // want to retry manually.
            try? await SupabaseService.shared.updateRecording(
                id: item.id,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            // Retry after a short delay, exponential up to a cap.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await processNext()
        }
    }

    private func upload(_ item: PendingRecording) async throws {
        guard let userId = SupabaseService.shared.currentUserId else {
            throw NSError(domain: "UploadQueue", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Signed out"
            ])
        }

        let storagePath = "\(userId.uuidString)/\(item.id.uuidString).m4a"

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

        // 5. Clean up the local file. (Comment this out if you want offline
        //    playback before the transcript is ready.)
        try? FileManager.default.removeItem(at: item.localFileURL)
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
