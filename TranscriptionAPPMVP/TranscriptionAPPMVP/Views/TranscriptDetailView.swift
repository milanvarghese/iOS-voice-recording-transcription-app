import SwiftUI
import AVFoundation
import Combine

@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published var isReady = false
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var errorMessage: String?

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var tempFileURL: URL?

    /// Prefer the on-device M4A; fall back to a Supabase signed URL if the
    /// local copy isn't there (e.g. fresh install, transcript-only listen).
    func load(for recording: Recording) async {
        if let localURL = AudioRecorder.localAudioURL(for: recording.id) {
            loadPlayer(from: localURL)
            return
        }
        guard let storagePath = recording.storagePath else {
            errorMessage = "Audio not available."
            return
        }
        do {
            let url = try await SupabaseService.shared.signedAudioURL(storagePath: storagePath)
            let (data, _) = try await URLSession.shared.data(from: url)
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(recording.id.uuidString).m4a")
            try data.write(to: temp)
            self.tempFileURL = temp
            loadPlayer(from: temp)
        } catch {
            errorMessage = "Couldn't load audio: \(error.localizedDescription)"
        }
    }

    private func loadPlayer(from url: URL) {
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            duration = p.duration
            isReady = true
        } catch {
            errorMessage = "Couldn't decode audio: \(error.localizedDescription)"
        }
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.timer?.invalidate()
                }
            }
        }
    }

    deinit {
        timer?.invalidate()
        player?.stop()
        if let tempFileURL {
            try? FileManager.default.removeItem(at: tempFileURL)
        }
    }
}

struct AudioPlayerView: View {
    @ObservedObject var vm: AudioPlayerViewModel

    var body: some View {
        VStack(spacing: 8) {
            if !vm.isReady {
                HStack {
                    ProgressView()
                    Text("Loading audio…").font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                HStack(spacing: 16) {
                    Button {
                        vm.togglePlay()
                    } label: {
                        Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: Binding(
                            get: { vm.currentTime },
                            set: { vm.seek(to: $0) }
                        ), in: 0...max(vm.duration, 0.01))
                        HStack {
                            Text(format(vm.currentTime))
                            Spacer()
                            Text(format(vm.duration))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            }
            if let err = vm.errorMessage {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct TranscriptDetailView: View {
    let recording: Recording
    @StateObject private var player = AudioPlayerViewModel()
    @State private var isRetrying = false
    @State private var retryError: String?
    @State private var isExtracting = false
    @State private var extractError: String?

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

                if hasPlayableAudio {
                    AudioPlayerView(vm: player)
                }

                Divider()

                switch recording.status {
                case .done:
                    if let transcript = recording.transcript, !transcript.isEmpty {
                        Text(transcript).textSelection(.enabled)
                    } else {
                        Text("Transcript is empty.").foregroundStyle(.secondary)
                    }
                    extractedFieldsSection
                case .transcribing, .uploaded, .uploading:
                    ProgressView("Transcribing…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                case .failed:
                    failedView
                case .draft:
                    Text("Recording not yet uploaded.").foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if hasPlayableAudio {
                await player.load(for: recording)
            }
        }
    }

    private var hasPlayableAudio: Bool {
        AudioRecorder.localAudioURL(for: recording.id) != nil || recording.storagePath != nil
    }

    @ViewBuilder
    private var extractedFieldsSection: some View {
        Divider()
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Extracted Fields").font(.headline)
                Spacer()
                Button {
                    Task { await runExtraction() }
                } label: {
                    if isExtracting {
                        ProgressView()
                    } else {
                        Image(systemName: recording.extractedFields == nil ? "sparkles" : "arrow.clockwise")
                    }
                }
                .disabled(isExtracting)
                .accessibilityLabel(recording.extractedFields == nil ? "Extract fields" : "Re-extract fields")
            }
            if let fields = recording.extractedFields {
                Text(fields.prettyPrinted())
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isExtracting {
                Text("Extracting…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("No fields extracted yet. Tap the sparkle icon to run extraction.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let err = extractError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func runExtraction() async {
        isExtracting = true
        extractError = nil
        defer { isExtracting = false }
        do {
            try await SupabaseService.shared.extractFields(recordingId: recording.id)
            // Realtime push will refresh the row; nothing else needed here.
        } catch {
            extractError = "Extraction failed: \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var failedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
            if let err = recording.errorMessage {
                Text(err).font(.footnote).foregroundStyle(.secondary)
            }
            if recording.storagePath != nil {
                Button {
                    Task { await retry() }
                } label: {
                    HStack {
                        if isRetrying { ProgressView().tint(.white) }
                        Text(isRetrying ? "Retrying…" : "Retry transcription")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying)
            } else {
                Text("Audio was never uploaded; can't retry transcription.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let err = retryError {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func retry() async {
        isRetrying = true
        retryError = nil
        defer { isRetrying = false }
        do {
            try await SupabaseService.shared.updateRecording(
                id: recording.id, status: .uploaded, errorMessage: ""
            )
            try await SupabaseService.shared.submitForTranscription(recordingId: recording.id)
            try await SupabaseService.shared.updateRecording(
                id: recording.id, status: .transcribing
            )
        } catch {
            retryError = error.localizedDescription
            try? await SupabaseService.shared.updateRecording(
                id: recording.id,
                status: .failed,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        return String(format: "%dm %ds", m, s)
    }
}
