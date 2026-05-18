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
                DocumentPreviewView(recording: recording, fields: fields)
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

/// Renders the extracted JSON as a printed-style document. White paper look
/// (forced regardless of system color scheme), sections per top-level key,
/// hand-written-style heading via system rounded font. Mainly a demo-quality
/// view — useful for showing the value of structured extraction to someone
/// who doesn't want to read raw JSON.
private struct DocumentPreviewView: View {
    let recording: Recording
    let fields: JSONValue

    // Paper-like palette, locked so it stays readable in both light & dark.
    private let paper = Color(red: 1.0, green: 0.99, blue: 0.97)
    private let ink = Color(red: 0.10, green: 0.10, blue: 0.14)
    private let dimInk = Color(red: 0.36, green: 0.38, blue: 0.45)
    private let rule = Color(red: 0.86, green: 0.85, blue: 0.82)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(rule)
            if let topLevel = topLevelObject {
                if let summary = topLevel["summary"], case .string(let text) = summary {
                    summarySection(text)
                }
                ForEach(orderedKeys(in: topLevel).filter { $0 != "summary" }, id: \.self) { key in
                    if let value = topLevel[key] {
                        section(key: key, value: value)
                    }
                }
            } else {
                Text("No structured fields available.")
                    .foregroundStyle(dimInk)
            }
            Divider().overlay(rule)
            footer
        }
        .padding(20)
        .background(paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(rule, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 6)
    }

    private var topLevelObject: [String: JSONValue]? {
        if case .object(let dict) = fields { return dict }
        return nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recording Report")
                .font(.system(.title2, design: .serif).weight(.semibold))
                .foregroundStyle(ink)
            Text(recording.title)
                .font(.footnote)
                .foregroundStyle(dimInk)
            HStack(spacing: 12) {
                Text(recording.createdAt, style: .date)
                Text("•")
                Text(formatDuration(recording.durationSeconds ?? 0))
            }
            .font(.caption2)
            .foregroundStyle(dimInk)
        }
    }

    private var footer: some View {
        HStack {
            Text("Generated by Claude Sonnet 4.6")
                .font(.caption2)
                .foregroundStyle(dimInk)
            Spacer()
            Text("TranscriptionAPPMVP")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(dimInk)
        }
    }

    @ViewBuilder
    private func summarySection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Summary".uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(dimInk)
            Text(text)
                .font(.system(.body, design: .serif))
                .foregroundStyle(ink)
                .textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func section(key: String, value: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(humanize(key).uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(dimInk)
            renderValue(value, depth: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func renderValue(_ value: JSONValue, depth: Int) -> some View {
        switch value {
        case .null:
            Text("—").foregroundStyle(dimInk)
        case .bool(let b):
            Text(b ? "Yes" : "No").foregroundStyle(ink)
        case .int(let i):
            Text(String(i)).foregroundStyle(ink)
        case .double(let d):
            Text(String(d)).foregroundStyle(ink)
        case .string(let s):
            Text(s)
                .font(.system(.body, design: .serif))
                .foregroundStyle(ink)
                .textSelection(.enabled)
        case .array(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(dimInk)
                        renderValue(item, depth: depth + 1)
                    }
                }
            }
        case .object(let dict):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(orderedKeys(in: dict), id: \.self) { k in
                    if let v = dict[k] {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(humanize(k)):")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(dimInk)
                            renderValue(v, depth: depth + 1)
                        }
                    }
                }
            }
        }
    }

    /// "action_items" → "Action items"
    private func humanize(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// Predictable section order: known important keys first, rest alphabetically.
    private func orderedKeys(in dict: [String: JSONValue]) -> [String] {
        let priority = [
            "summary", "title", "subject", "main_idea",
            "attendees", "people_mentioned", "interviewee", "customer_name",
            "action_items", "todos", "next_steps",
            "key_decisions", "decisions",
            "deadlines", "dates_mentioned", "next_meeting",
            "organizations", "store",
            "key_topics", "topics", "key_concepts",
            "items", "symptoms", "medications_mentioned",
            "pain_points", "budget_signals",
            "key_quotes",
            "sentiment", "mood"
        ]
        let present = Set(dict.keys)
        var ordered: [String] = []
        for k in priority where present.contains(k) {
            ordered.append(k)
        }
        for k in dict.keys.sorted() where !ordered.contains(k) {
            ordered.append(k)
        }
        return ordered
    }

    private func formatDuration(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 { return String(format: "%dh %dm", h, m) }
        return String(format: "%dm %ds", m, s)
    }
}
