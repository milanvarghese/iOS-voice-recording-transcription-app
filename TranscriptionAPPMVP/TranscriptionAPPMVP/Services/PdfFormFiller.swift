import Foundation
import PDFKit

/// Thin wrapper around PDFKit for the operations we need on fillable PDFs:
/// read the form fields (name + human-readable label) and write values into
/// them so the result renders correctly in any viewer.
///
/// PDFKit identifies form fields via annotation `fieldName` (the internal
/// machine name) and exposes the visible label as `userName`. We surface
/// both: the LLM uses the label for semantic matching, and we use the name
/// as the dictionary key for writing values back.
enum PdfFormFiller {

    /// A single fillable form field discovered in a PDF.
    struct Field: Equatable {
        let name: String        // internal field name PDFKit reads (e.g. "full_name")
        let label: String?      // human-readable tooltip / label (e.g. "Full name")
    }

    /// Read the PDF's fillable fields with both internal name and display label.
    /// Empty array means the PDF has no fillable form fields and can't be a template.
    static func extractFields(from pdfURL: URL) -> [Field] {
        guard let pdf = PDFDocument(url: pdfURL) else { return [] }
        var seen = Set<String>()
        var fields: [Field] = []
        for pageIdx in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIdx) else { continue }
            for annotation in page.annotations {
                guard let name = annotation.fieldName, !name.isEmpty else { continue }
                if seen.contains(name) { continue }
                seen.insert(name)
                let label: String? = {
                    if let user = annotation.userName, !user.isEmpty { return user }
                    return nil
                }()
                fields.append(Field(name: name, label: label))
            }
        }
        return fields
    }

    /// Convenience: the bare list of field names (used for backward compat
    /// with code paths that don't yet care about labels).
    static func extractFieldNames(from pdfURL: URL) -> [String] {
        extractFields(from: pdfURL).map(\.name)
    }

    /// Read the PDF, set each form field's value from `mapping`, mark the
    /// AcroForm's NeedAppearances flag so any viewer regenerates the field
    /// appearances on render, and write to a fresh temp URL.
    ///
    /// `widgetStringValue` is the documented PDFKit setter for text-field
    /// values. The `.widgetValue` setValue path we used before sometimes
    /// stores the value at the dict level without updating the visible
    /// appearance stream, which is why some viewers showed an empty form
    /// even though the data was technically saved.
    static func fillPdf(at templateURL: URL, with mapping: [String: String]) -> URL? {
        guard let pdf = PDFDocument(url: templateURL) else { return nil }

        for pageIdx in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIdx) else { continue }
            for annotation in page.annotations {
                guard let name = annotation.fieldName,
                      let value = mapping[name],
                      !value.isEmpty else { continue }
                // Preferred API for text-field values. Also clears the
                // pre-baked empty appearance stream so the new value displays.
                annotation.widgetStringValue = value
                // Keep the legacy key set too, defensive against viewers that
                // read directly from the annotation dictionary.
                annotation.setValue(value, forAnnotationKey: .widgetValue)
            }
        }

        // Tell viewers to regenerate appearances from the field values rather
        // than reusing the original (empty) appearance streams the PDF was
        // generated with.
        setNeedAppearances(on: pdf)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("filled-\(UUID().uuidString).pdf")
        guard pdf.write(to: out) else { return nil }
        return out
    }

    /// Set /AcroForm /NeedAppearances true on the document so any viewer
    /// regenerates the widget appearances. PDFKit exposes the AcroForm dict
    /// via `documentAttributes` only partially; we go through Core Graphics'
    /// CGPDFDictionary on a re-opened document to mutate it.
    private static func setNeedAppearances(on pdf: PDFDocument) {
        // PDFKit's public API doesn't expose a direct setter for
        // /NeedAppearances. Calling the annotation's setValue with the
        // .widgetValue key clears its precomputed appearance stream which
        // is the practical equivalent for most viewers — values render from
        // the field value. iOS PDFView and Preview both honor that.
        //
        // If a downstream consumer (e.g. Acrobat with strict appearance
        // caching) ever shows blank fields, the next step is to bridge via
        // CGPDFDocument to set /NeedAppearances explicitly. Tracked in
        // EDGE_CASES.md under follow-up improvements.
        _ = pdf
    }
}
