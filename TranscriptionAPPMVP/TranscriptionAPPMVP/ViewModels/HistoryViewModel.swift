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

    func delete(_ recording: Recording) async {
        do {
            try await SupabaseService.shared.deleteRecording(
                id: recording.id,
                storagePath: recording.storagePath
            )
            recordings.removeAll { $0.id == recording.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
