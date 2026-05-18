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
    /// Human-readable label for each field name (PDF widget `userName` /
    /// tooltip text). Lets the LLM semantically map values onto a field
    /// whose internal name is opaque (e.g. "Text1") but whose label is
    /// "Patient's full name".
    var fieldLabels: [String: String]?
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case storagePath = "storage_path"
        case fieldNames = "field_names"
        case fieldLabels = "field_labels"
        case createdAt = "created_at"
    }
}
