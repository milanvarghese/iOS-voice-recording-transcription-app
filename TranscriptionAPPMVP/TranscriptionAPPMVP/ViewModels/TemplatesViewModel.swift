import Foundation
import Combine

@MainActor
final class TemplatesViewModel: ObservableObject {
    @Published var templates: [PdfTemplate] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            templates = try await SupabaseService.shared.fetchTemplates()
        } catch {
            errorMessage = "Couldn't load templates: \(error.localizedDescription)"
        }
    }

    /// Upload a PDF picked from Files. We extract fillable field names with
    /// PDFKit BEFORE uploading so we can refuse non-fillable PDFs cleanly.
    /// Returns the new template on success, nil on failure (with errorMessage set).
    func uploadTemplate(from fileURL: URL, name: String) async -> PdfTemplate? {
        // iOS gives us a security-scoped URL when the user picks from Files.
        let didStartAccess = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { fileURL.stopAccessingSecurityScopedResource() }
        }

        let fields = PdfFormFiller.extractFieldNames(from: fileURL)
        guard !fields.isEmpty else {
            errorMessage = "That PDF has no fillable form fields. Templates need annotation-level fields (use Acrobat / Preview to add them)."
            return nil
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let template = try await SupabaseService.shared.uploadTemplate(
                name: name,
                pdfData: data,
                fieldNames: fields
            )
            templates.insert(template, at: 0)
            return template
        } catch {
            errorMessage = "Upload failed: \(error.localizedDescription)"
            return nil
        }
    }

    func delete(_ template: PdfTemplate) async {
        do {
            try await SupabaseService.shared.deleteTemplate(template)
            templates.removeAll { $0.id == template.id }
        } catch {
            errorMessage = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    /// The full fill-template pipeline:
    ///   1. Ask Claude (via Edge Function) for a {field: value} mapping.
    ///   2. Download the template PDF.
    ///   3. Write the mapping into the PDF using PDFKit.
    ///   4. Return the filled PDF's local file URL.
    /// Errors throw so the caller can show a single failure surface.
    func fillTemplate(_ template: PdfTemplate, with recording: Recording) async throws -> URL {
        let mapping = try await SupabaseService.shared.mapToTemplate(
            recordingId: recording.id,
            templateId: template.id
        )

        let pdfData = try await SupabaseService.shared.downloadTemplate(template)
        let tempTemplate = FileManager.default.temporaryDirectory
            .appendingPathComponent("template-\(UUID().uuidString).pdf")
        try pdfData.write(to: tempTemplate)

        guard let filledURL = PdfFormFiller.fillPdf(at: tempTemplate, with: mapping) else {
            throw NSError(domain: "TemplatesViewModel", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "PDFKit couldn't write the filled PDF."
            ])
        }
        // Clean up the unfilled temp copy.
        try? FileManager.default.removeItem(at: tempTemplate)
        return filledURL
    }
}
