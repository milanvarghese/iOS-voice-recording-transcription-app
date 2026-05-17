import SwiftUI

struct TranscriptDetailView: View {
    let recording: Recording

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(recording.title).font(.title2.bold())
                HStack {
                    Label(formatDuration(recording.durationSeconds ?? 0), systemImage: "clock")
                    Spacer()
                    Text(recording.createdAt, style: .date)
                }
                .foregroundStyle(.secondary)
                .font(.footnote)

                Divider()

                switch recording.status {
                case .done:
                    if let transcript = recording.transcript, !transcript.isEmpty {
                        Text(transcript)
                            .textSelection(.enabled)
                    } else {
                        Text("Transcript is empty.").foregroundStyle(.secondary)
                    }
                case .transcribing, .uploaded, .uploading:
                    ProgressView("Transcribing…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                case .failed:
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Something went wrong", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        if let err = recording.errorMessage {
                            Text(err).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                case .draft:
                    Text("Recording not yet uploaded.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        return String(format: "%dm %ds", m, s)
    }
}
