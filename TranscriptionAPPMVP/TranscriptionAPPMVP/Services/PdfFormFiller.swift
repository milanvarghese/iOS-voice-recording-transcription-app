import Foundation
import PDFKit

/// Thin wrapper around PDFKit for the two operations we care about with
/// fillable PDFs: read the form field names, and write values into them.
///
/// PDFKit identifies form fields via annotation `fieldName`. PDFs created
/// with Acrobat / Preview / similar editors carry these names when fields
/// are explicitly added. Scanned PDFs without annotation-level fields are
/// not supported (the field names array will be empty).
enum PdfFormFiller {

    /// Reads a PDF file and returns the unique field names of every form
    /// annotation in document order. Empty array means the PDF has no
    /// fillable fields (and isn't usable as a template here).
    static func extractFieldNames(from pdfURL: URL) -> [String] {
        guard let pdf = PDFDocument(url: pdfURL) else { return [] }
        var seen = Set<String>()
        var ordered: [String] = []
        for pageIdx in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIdx) else { continue }
            for annotation in page.annotations {
                guard let name = annotation.fieldName, !name.isEmpty else { continue }
                if !seen.contains(name) {
                    seen.insert(name)
                    ordered.append(name)
                }
            }
        }
        return ordered
    }

    /// Reads the PDF, sets each form field's value from the mapping, and
    /// writes the filled PDF to a fresh URL in the temporary directory.
    /// Returns the filled PDF's URL, or nil on failure.
    static func fillPdf(at templateURL: URL, with mapping: [String: String]) -> URL? {
        guard let pdf = PDFDocument(url: templateURL) else { return nil }

        for pageIdx in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIdx) else { continue }
            for annotation in page.annotations {
                guard let name = annotation.fieldName,
                      let value = mapping[name],
                      !value.isEmpty else { continue }
                // PDFAnnotation widget value setter; works for text, checkbox,
                // choice, etc. For checkboxes the convention is "Yes"/"Off",
                // which we don't enforce here — assume the mapping is text.
                annotation.setValue(value, forAnnotationKey: .widgetValue)
            }
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("filled-\(UUID().uuidString).pdf")
        guard pdf.write(to: out) else { return nil }
        return out
    }
}
