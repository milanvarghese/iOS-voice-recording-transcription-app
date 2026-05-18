import SwiftUI

struct HistoryView: View {
    @StateObject private var vm = HistoryViewModel()
    @State private var renaming: Recording?
    @State private var newTitle: String = ""
    @State private var pendingForeverDelete: Recording?

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.recordings.isEmpty {
                    ProgressView()
                } else if vm.recordings.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet",
                        systemImage: "waveform",
                        description: Text("Tap Record to capture your first audio.")
                    )
                } else {
                    List {
                        ForEach(vm.recordings) { recording in
                            NavigationLink {
                                TranscriptDetailView(recording: recording)
                            } label: {
                                RecordingRow(recording: recording)
                            }
                            .swipeActions(edge: .trailing) {
                                // Destructive cloud delete sits at the outer
                                // edge so it requires more intent.
                                Button(role: .destructive) {
                                    pendingForeverDelete = recording
                                } label: { Label("Delete", systemImage: "trash") }

                                Button {
                                    vm.removeFromPhone(recording)
                                } label: { Label("Remove from Phone", systemImage: "iphone.slash") }
                                .tint(.orange)

                                Button {
                                    newTitle = recording.title
                                    renaming = recording
                                } label: { Label("Rename", systemImage: "pencil") }
                                .tint(.blue)
                            }
                        }
                    }
                    .refreshable { await vm.load() }
                }
            }
            .navigationTitle("History")
            .task {
                await vm.load()
                await vm.startListening()
            }
            .alert("Rename recording", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Title", text: $newTitle)
                Button("Save") {
                    if let r = renaming {
                        Task { await vm.rename(r, to: newTitle) }
                    }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog(
                "Delete this recording everywhere?",
                isPresented: Binding(
                    get: { pendingForeverDelete != nil },
                    set: { if !$0 { pendingForeverDelete = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingForeverDelete
            ) { recording in
                Button("Delete from cloud + phone", role: .destructive) {
                    Task { await vm.deleteForever(recording) }
                    pendingForeverDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingForeverDelete = nil
                }
            } message: { _ in
                Text("The audio file and transcript will be permanently removed from cloud storage. This can't be undone.")
            }
        }
    }
}

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title).font(.headline)
                HStack(spacing: 8) {
                    Text(formatDuration(recording.durationSeconds ?? 0))
                        .foregroundStyle(.secondary)
                        .font(.footnote.monospacedDigit())
                    statusBadge
                }
            }
            Spacer()
            if recording.status == .transcribing || recording.status == .uploading {
                ProgressView()
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        let (label, color): (String, Color) = {
            switch recording.status {
            case .draft:        return ("Draft", .gray)
            case .uploading:    return ("Uploading…", .blue)
            case .uploaded:     return ("Uploaded", .blue)
            case .transcribing: return ("Transcribing…", .orange)
            case .done:         return ("Ready", .green)
            case .failed:       return ("Failed", .red)
            }
        }()
        return Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}
