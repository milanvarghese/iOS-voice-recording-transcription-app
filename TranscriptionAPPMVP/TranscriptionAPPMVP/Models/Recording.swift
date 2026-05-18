import Foundation

enum RecordingStatus: String, Codable {
    case draft        // created locally, nothing uploaded yet
    case uploading
    case uploaded
    case transcribing
    case done
    case failed
}

/// A flexible JSON value used for fields whose schema isn't known at compile
/// time. extracted_fields is the main example — Claude adapts its output to
/// the transcript content, so the keys aren't fixed.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON shape")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Pretty-printed JSON with sorted keys. Used to render extracted_fields
    /// in the transcript detail view.
    func prettyPrinted() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
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
    var extractedFields: JSONValue?
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
        case extractedFields = "extracted_fields"
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
