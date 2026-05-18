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
            _ = try? await client.storage
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

    /// A 1-hour signed URL for a private audio file. Used when the local copy
    /// isn't on the phone (fresh install, switched devices) so playback can
    /// stream from Supabase Storage.
    func signedAudioURL(storagePath: String) async throws -> URL {
        try await client.storage
            .from(Config.storageBucket)
            .createSignedURL(path: storagePath, expiresIn: 60 * 60)
    }

    /// Upload an audio file. supabase-swift uses resumable upload under the hood
    /// for files >6MB, which matters for hour-long recordings.
    /// Uses memory-mapped file reading so a multi-hour M4A doesn't load its
    /// entire byte length into RAM at once.
    func uploadAudio(localURL: URL, storagePath: String) async throws {
        let data = try Data(contentsOf: localURL, options: [.mappedIfSafe])
        _ = try await client.storage
            .from(Config.storageBucket)
            .upload(
                storagePath,
                data: data,
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

    /// Re-runs Claude-based field extraction on a transcript that already
    /// exists. The webhook chains this automatically once a transcript lands;
    /// iOS calls it from the detail view for manual re-extraction.
    func extractFields(recordingId: UUID) async throws {
        struct Body: Encodable { let recording_id: String }
        try await client.functions.invoke(
            "extract_fields",
            options: .init(body: Body(recording_id: recordingId.uuidString))
        )
    }

    // MARK: - PDF templates

    /// Lists the current user's saved templates, newest first.
    func fetchTemplates() async throws -> [PdfTemplate] {
        try await client
            .from("pdf_templates")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    /// Uploads a PDF blob to the pdf-templates bucket at <user_id>/<id>.pdf
    /// and inserts a matching pdf_templates row carrying the detected field
    /// names. Returns the inserted row.
    func uploadTemplate(name: String, pdfData: Data, fieldNames: [String]) async throws -> PdfTemplate {
        guard let userId = currentUserId else {
            throw NSError(domain: "SupabaseService", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "Not signed in"
            ])
        }
        let templateId = UUID()
        let storagePath = "\(userId.uuidString.lowercased())/\(templateId.uuidString.lowercased()).pdf"

        _ = try await client.storage
            .from("pdf-templates")
            .upload(
                storagePath,
                data: pdfData,
                options: FileOptions(contentType: "application/pdf", upsert: false)
            )

        let row = PdfTemplate(
            id: templateId,
            userId: userId,
            name: name,
            storagePath: storagePath,
            fieldNames: fieldNames,
            createdAt: Date()
        )
        try await client.from("pdf_templates").insert(row).execute()
        return row
    }

    /// Removes a template's PDF from Storage and its DB row. Use after the
    /// user explicitly confirms deletion.
    func deleteTemplate(_ template: PdfTemplate) async throws {
        _ = try? await client.storage
            .from("pdf-templates")
            .remove(paths: [template.storagePath])
        try await client
            .from("pdf_templates")
            .delete()
            .eq("id", value: template.id)
            .execute()
    }

    /// Downloads the template PDF bytes from Storage. The result is written
    /// to disk by the caller before being handed to PDFKit.
    func downloadTemplate(_ template: PdfTemplate) async throws -> Data {
        try await client.storage
            .from("pdf-templates")
            .download(path: template.storagePath)
    }

    /// Calls the map_to_template Edge Function and returns the
    /// {field_name: value} mapping Claude produced.
    func mapToTemplate(recordingId: UUID, templateId: UUID) async throws -> [String: String] {
        struct Body: Encodable {
            let recording_id: String
            let template_id: String
        }
        struct Response: Decodable {
            let ok: Bool
            let mapping: [String: String]
        }
        let resp: Response = try await client.functions.invoke(
            "map_to_template",
            options: .init(body: Body(
                recording_id: recordingId.uuidString,
                template_id: templateId.uuidString
            ))
        )
        return resp.mapping
    }
}

/// Stub — supabase-swift provides default in-memory storage for sessions.
/// Replace with keychain if you want sessions to survive app reinstalls.
struct SupabaseAuthKeychainStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws { UserDefaults.standard.set(value, forKey: key) }
    func retrieve(key: String) throws -> Data? { UserDefaults.standard.data(forKey: key) }
    func remove(key: String) throws { UserDefaults.standard.removeObject(forKey: key) }
}
