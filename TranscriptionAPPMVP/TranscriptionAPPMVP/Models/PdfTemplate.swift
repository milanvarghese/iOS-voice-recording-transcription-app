import Foundation

/// Mirrors public.pdf_templates. A user's saved fillable-PDF template that
/// can be used to generate filled documents from any recording's transcript
/// + extracted fields.
struct PdfTemplate: Identifiable, Codable, Equatable {
    var id: UUID
    var userId: UUID
    var name: String
    var storagePath: String
    var fieldNames: [String]?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case storagePath = "storage_path"
        case fieldNames = "field_names"
        case createdAt = "created_at"
    }
}
