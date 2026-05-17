import Foundation

enum RecordingStatus: String, Codable {
    case draft        // created locally, nothing uploaded yet
    case uploading
    case uploaded
    case transcribing
    case done
    case failed
}

/// Mirrors the public.recordings row in Postgres.
/// Codable so it round-trips through supabase-swift's PostgREST client.
struct Recording: Identifiable, Codable, Equatable {
    var id: UUID
    var userId: UUID
    var title: String
    var durationSeconds: Int?
    var status: RecordingStatus
    var storagePath: String?
    var assemblyaiId: String?
    var transcript: String?
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case durationSeconds = "duration_seconds"
        case status
        case storagePath = "storage_path"
        case assemblyaiId = "assemblyai_id"
        case transcript
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// A pending upload that lives entirely on-device until storage_path is set.
struct PendingRecording: Identifiable, Codable {
    let id: UUID
    let localFileURL: URL
    let durationSeconds: Int
    let title: String
    let createdAt: Date
}
