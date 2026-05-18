import Foundation
import Combine
import Supabase

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var errorMessage: String?
    @Published var isLoading = false

    private var realtimeChannel: RealtimeChannelV2?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            recordings = try await SupabaseService.shared.fetchRecordings()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Subscribe to row changes so the list updates when AssemblyAI's webhook
    /// writes a transcript. No polling required.
    func startListening() async {
        // Stop any previous channel.
        if let channel = realtimeChannel {
            await channel.unsubscribe()
        }
        let channel = SupabaseService.shared.client
            .realtimeV2
            .channel("public:recordings")

        let changes = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "recordings"
        )

        do {
            try await channel.subscribeWithError()
            self.realtimeChannel = channel
        } catch {
            errorMessage = "Realtime subscription failed: \(error.localizedDescription)"
            return
        }

        Task {
            for await _ in changes {
                await self.load()
            }
        }
    }

    func rename(_ recording: Recording, to newTitle: String) async {
        do {
            try await SupabaseService.shared.updateRecording(id: recording.id, title: newTitle)
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Remove only the local audio cache. Cloud copy + DB row are preserved
    /// — the recording stays in History, and the audio re-downloads on next
    /// play. Use this to free up space without losing the recording.
    func removeFromPhone(_ recording: Recording) {
        AudioRecorder.deleteLocalAudio(for: recording.id)
        objectWillChange.send()
    }

    /// Delete a recording everywhere: cloud storage, DB row, and local cache.
    /// Irreversible. Call this only when the user has explicitly confirmed.
    func deleteForever(_ recording: Recording) async {
        do {
            try await SupabaseService.shared.deleteRecording(
                id: recording.id,
                storagePath: recording.storagePath
            )
            AudioRecorder.deleteLocalAudio(for: recording.id)
            recordings.removeAll { $0.id == recording.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Retry transcription for a failed recording. Only valid when the audio
    /// already made it to Supabase Storage (recording.storagePath != nil).
    func retryTranscription(_ recording: Recording) async {
        guard recording.storagePath != nil else {
            errorMessage = "Can't retry: audio was never uploaded."
            return
        }
        do {
            try await SupabaseService.shared.updateRecording(
                id: recording.id, status: .uploaded
            )
            try await SupabaseService.shared.submitForTranscription(recordingId: recording.id)
            try await SupabaseService.shared.updateRecording(
                id: recording.id, status: .transcribing
            )
        } catch {
            errorMessage = "Retry failed: \(error.localizedDescription)"
            try? await SupabaseService.shared.updateRecording(
                id: recording.id,
                status: .failed,
                errorMessage: error.localizedDescription
            )
        }
    }
}
