import SwiftUI
import AVFoundation
import Combine
import UIKit

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
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(Color(red: 0.65, green: 0.4, blue: 1.0))
                    Text("Extracted Fields").font(.headline)
                }
                Spacer()
                Button {
                    Task { await runExtraction() }
                } label: {
                    if isExtracting {
                        ProgressView()
                    } else {
                        Image(systemName: recording.extractedFields == nil ? "wand.and.stars" : "arrow.clockwise")
                    }
                }
                .disabled(isExtracting)
                .accessibilityLabel(recording.extractedFields == nil ? "Extract fields" : "Re-extract fields")
            }
            if let fields = recording.extractedFields {
                CodeBlockView(json: fields.prettyPrinted())
            } else if isExtracting {
                CodeBlockView(json: "{\n  \"status\": \"extracting…\"\n}")
            } else {
                CodeBlockView(json: "{\n  \"hint\": \"Tap the wand icon to run extraction.\"\n}")
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

/// Dark code-editor style block for pretty-printed JSON, with simple syntax
/// highlighting (keys, strings, numbers, booleans / null).
private struct CodeBlockView: View {
    let json: String

    var body: some View {
        Text(highlight(json))
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.08, green: 0.09, blue: 0.12),
                        Color(red: 0.05, green: 0.06, blue: 0.09)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    /// Color palette is loosely inspired by VSCode's dark+ theme.
    private func highlight(_ text: String) -> AttributedString {
        let mutable = NSMutableAttributedString(string: text)
        let full = NSRange(location: 0, length: (text as NSString).length)

        let baseColor = UIColor(red: 0.86, green: 0.87, blue: 0.92, alpha: 1)
        let keyColor = UIColor(red: 0.40, green: 0.78, blue: 1.00, alpha: 1)
        let stringColor = UIColor(red: 0.96, green: 0.73, blue: 0.49, alpha: 1)
        let numberColor = UIColor(red: 0.62, green: 0.92, blue: 0.55, alpha: 1)
        let boolColor = UIColor(red: 0.85, green: 0.55, blue: 1.00, alpha: 1)
        let punctColor = UIColor(red: 0.55, green: 0.57, blue: 0.65, alpha: 1)

        mutable.addAttribute(.foregroundColor, value: baseColor, range: full)

        // Order matters: keys override generic-string color where they overlap.
        let stringPattern = #""[^"\\]*(?:\\.[^"\\]*)*""#
        apply(stringPattern, in: mutable, range: full, color: stringColor)

        let keyPattern = #""[^"\\]*(?:\\.[^"\\]*)*"(?=\s*:)"#
        apply(keyPattern, in: mutable, range: full, color: keyColor)

        let numberPattern = #"(?<![\w."])-?\d+(?:\.\d+)?(?![\w."])"#
        apply(numberPattern, in: mutable, range: full, color: numberColor)

        let boolPattern = #"\b(true|false|null)\b"#
        apply(boolPattern, in: mutable, range: full, color: boolColor)

        let punctPattern = #"[\{\}\[\]:,]"#
        apply(punctPattern, in: mutable, range: full, color: punctColor)

        return AttributedString(mutable)
    }

    private func apply(_ pattern: String, in attr: NSMutableAttributedString, range: NSRange, color: UIColor) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        regex.enumerateMatches(in: attr.string, range: range) { match, _, _ in
            guard let r = match?.range else { return }
            attr.addAttribute(.foregroundColor, value: color, range: r)
        }
    }
}
