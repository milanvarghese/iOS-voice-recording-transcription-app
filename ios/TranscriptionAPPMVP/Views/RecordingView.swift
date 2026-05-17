import SwiftUI

struct RecordingView: View {
    @StateObject private var vm = RecorderViewModel()
    @State private var showDiscardConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Big timer — bound to the actual recorder.currentTime, never a separate counter.
                Text(formatDuration(vm.elapsedSeconds))
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(vm.isRecording ? .red : .primary)

                // Live audio level meter (a simple bar). Gives the user visual proof
                // that audio is actually being captured. Concern #1: "recording but
                // captures nothing" — if this bar never moves, the mic isn't working.
                LevelMeter(level: vm.audioLevel, active: vm.isRecording && !vm.isPaused)
                    .frame(height: 60)
                    .padding(.horizontal)

                Spacer()

                controls

                if let error = vm.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle("Record")
            .confirmationDialog(
                "Discard this recording? It cannot be recovered.",
                isPresented: $showDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { vm.discard() }
                Button("Keep recording", role: .cancel) {}
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            if vm.isRecording {
                // Discard (cancel) — concern #4
                Button {
                    showDiscardConfirm = true
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.title)
                        .frame(width: 60, height: 60)
                        .background(Color.gray.opacity(0.2), in: Circle())
                }
                .accessibilityLabel("Discard recording")

                // Pause / resume
                Button {
                    vm.togglePause()
                } label: {
                    Image(systemName: vm.isPaused ? "play.fill" : "pause.fill")
                        .font(.title)
                        .frame(width: 60, height: 60)
                        .background(Color.yellow.opacity(0.2), in: Circle())
                }

                // Stop and upload
                Button {
                    vm.stopAndUpload()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .background(Color.red, in: Circle())
                }
            } else {
                Button {
                    vm.startRecording()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .background(Color.red, in: Circle())
                }
                .accessibilityLabel("Start recording")
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

struct LevelMeter: View {
    let level: Float
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { i in
                    let threshold = Float(i) / 24
                    Capsule()
                        .fill(active && level > threshold ? Color.red : Color.gray.opacity(0.3))
                        .frame(width: (geo.size.width - 23 * 3) / 24)
                }
            }
            .animation(.easeOut(duration: 0.08), value: level)
        }
    }
}
