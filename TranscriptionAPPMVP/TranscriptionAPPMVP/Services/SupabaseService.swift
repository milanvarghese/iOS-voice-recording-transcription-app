import Combine
import Foundation
import Supabase

/// Single source of truth for the Supabase client.
/// Add the `supabase-swift` Swift package: https://github.com/supabase/supabase-swift
@MainActor
final class SupabaseService: ObservableObject {
    static let shared = SupabaseService()

    let client: SupabaseClient

    private init() {
        self.client = SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabaseAnonKey,
            options: .init(
                db: .init(),
                auth: .init(
                    storage: SupabaseAuthKeychainStorage(),  // keychain so session survives reinstall? no — survives backgrounding
                    flowType: .pkce
                )
            )
        )
    }

    // MARK: - Auth

    func sendOTP(email: String) async throws {
        try await client.auth.signInWithOTP(
            email: email,
            redirectTo: nil,
            shouldCreateUser: true
        )
    }

    func verifyOTP(email: String, code: String) async throws {
        _ = try await client.auth.verifyOTP(
            email: email,
            token: code,
            type: .email
        )
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    var currentUserId: UUID? {
        client.auth.currentUser?.id
    }

    // MARK: - Recordings

    /// Insert a placeholder row before we start uploading.
    /// We use the same UUID locally and remotely so the file path is predictable.
    func insertRecording(_ recording: Recording) async throws {
        try await client
            .from("recordings")
            .insert(recording)
            .execute()
    }

    func updateRecording(
        id: UUID,
        status: RecordingStatus? = nil,
        storagePath: String? = nil,
        durationSeconds: Int? = nil,
        title: String? = nil,
        errorMessage: String? = nil
    ) async throws {
        struct Patch: Encodable {
            var status: RecordingStatus?
            var storage_path: String?
            var duration_seconds: Int?
            var title: String?
            var error_message: String?
        }
        let patch = Patch(
            status: status,
            storage_path: storagePath,
            duration_seconds: durationSeconds,
            title: title,
            error_message: errorMessage
        )
        try await client
            .from("recordings")
            .update(patch)
            .eq("id", value: id)
            .execute()
    }

    func deleteRecording(id: UUID, storagePath: String?) async throws {
        if let storagePath {
            try? await client.storage
                .from(Config.storageBucket)
                .remove(paths: [storagePath])
        }
        try await client
            .from("recordings")
            .delete()
            .eq("id", value: id)
            .execute()
    }

    func fetchRecordings() async throws -> [Recording] {
        try await client
            .from("recordings")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    // MARK: - Storage

    /// Upload an audio file. supabase-swift uses resumable upload under the hood
    /// for files >6MB, which matters for hour-long recordings.
    func uploadAudio(localURL: URL, storagePath: String) async throws {
        let data = try Data(contentsOf: localURL)
        _ = try await client.storage
            .from(Config.storageBucket)
            .upload(
                path: storagePath,
                file: data,
                options: FileOptions(
                    contentType: "audio/m4a",
                    upsert: true
                )
            )
    }

    // MARK: - Edge Function

    /// Triggers the Edge Function that submits the recording to AssemblyAI.
    func submitForTranscription(recordingId: UUID) async throws {
        struct Body: Encodable { let recording_id: String }
        try await client.functions.invoke(
            "submit_for_transcription",
            options: .init(body: Body(recording_id: recordingId.uuidString))
        )
    }
}

/// Stub — supabase-swift provides default in-memory storage for sessions.
/// Replace with keychain if you want sessions to survive app reinstalls.
struct SupabaseAuthKeychainStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws { UserDefaults.standard.set(value, forKey: key) }
    func retrieve(key: String) throws -> Data? { UserDefaults.standard.data(forKey: key) }
    func remove(key: String) throws { UserDefaults.standard.removeObject(forKey: key) }
}
