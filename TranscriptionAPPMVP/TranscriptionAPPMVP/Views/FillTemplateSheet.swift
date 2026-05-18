import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Sheet opened from the transcript detail view. Shows the user's templates,
/// lets them upload a new fillable PDF, and on tap runs the fill pipeline
/// and pushes a preview of the resulting PDF.
struct FillTemplateSheet: View {
    let recording: Recording
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = TemplatesViewModel()
    @State private var showingFileImporter = false
    @State private var newTemplateName = ""
    @State private var pickedFileURL: URL?
    @State private var showingNameAlert = false
    @State private var isFilling = false
    @State private var filledPdfURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.templates.isEmpty {
                    ProgressView()
                } else {
                    List {
                        if vm.templates.isEmpty {
                            Section {
                                ContentUnavailableView(
                                    "No templates yet",
                                    systemImage: "doc.text",
                                    description: Text("Upload a fillable PDF (with named form fields) to fill it from this recording's transcript.")
                                )
                            }
                        } else {
                            Section("Your templates") {
                                ForEach(vm.templates) { template in
                                    Button {
                                        fill(template)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(template.name).font(.body)
                                            Text("\(template.fieldNames?.count ?? 0) field(s)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .swipeActions {
                                        Button(role: .destructive) {
                                            Task { await vm.delete(template) }
                                        } label: { Label("Delete", systemImage: "trash") }
                                    }
                                }
                            }
                        }

                        Section {
                            Button {
                                showingFileImporter = true
                            } label: {
                                Label("Upload a new PDF template", systemImage: "plus.circle.fill")
                            }
                        }

                        if isFilling {
                            Section {
                                HStack {
                                    ProgressView()
                                    Text("Filling template…")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if let err = vm.errorMessage {
                            Section {
                                Text(err)
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Fill template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await vm.load() }
            .fileImporter(
                isPresented: $showingFileImporter,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        pickedFileURL = url
                        newTemplateName = url.deletingPathExtension().lastPathComponent
                        showingNameAlert = true
                    }
                case .failure(let err):
                    vm.errorMessage = "Couldn't pick file: \(err.localizedDescription)"
                }
            }
            .alert("Name this template", isPresented: $showingNameAlert) {
                TextField("Template name", text: $newTemplateName)
                Button("Cancel", role: .cancel) {
                    pickedFileURL = nil
                }
                Button("Upload") {
                    if let url = pickedFileURL {
                        Task { _ = await vm.uploadTemplate(from: url, name: newTemplateName) }
                    }
                    pickedFileURL = nil
                }
            } message: {
                Text("Pick a short name you'll recognize later.")
            }
            .sheet(item: Binding(
                get: { filledPdfURL.map(FilledPdfItem.init) },
                set: { newValue in filledPdfURL = newValue?.url }
            )) { item in
                FilledPdfPreviewView(pdfURL: item.url, templateName: "Filled document")
            }
        }
    }

    private func fill(_ template: PdfTemplate) {
        isFilling = true
        Task {
            defer { isFilling = false }
            do {
                let url = try await vm.fillTemplate(template, with: recording)
                filledPdfURL = url
            } catch {
                vm.errorMessage = "Fill failed: \(error.localizedDescription)"
            }
        }
    }
}

/// Wraps a URL so SwiftUI's .sheet(item:) can present off a non-Identifiable value.
private struct FilledPdfItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// PDFKit-backed preview of the filled PDF with a Share button. Lets the
/// user export the filled doc to Files, Mail, AirDrop, etc.
struct FilledPdfPreviewView: View {
    let pdfURL: URL
    let templateName: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            PDFKitRepresented(url: pdfURL)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(templateName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: pdfURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
        }
    }
}

private struct PDFKitRepresented: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
