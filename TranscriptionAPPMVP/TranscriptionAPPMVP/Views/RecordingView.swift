import SwiftUI

struct RecordingView: View {
    @StateObject private var vm = RecorderViewModel()
    @State private var showDiscardConfirm = false
    @State private var showOrphanDiscardConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Orphan card — shown when iOS killed the app mid-recording
                // and the M4A is still on disk. User picks one of three.
                if let orphan = vm.pendingOrphan, !vm.isRecording {
                    orphanCard(for: orphan)
                }

                // Status pill — only visible during a recording session so the
                // user always knows whether they're capturing audio or paused.
                if vm.isRecording {
                    statusBadge
                }

                // Big timer — bound to AVAudioRecorder.currentTime, never a
                // separate counter. Color shifts to a muted gray when paused
                // so it's obvious nothing is being captured.
                Text(formatDuration(vm.elapsedSeconds))
                    .font(.system(size: 64, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(timerColor)
                    .animation(.easeInOut(duration: 0.15), value: vm.isPaused)

                // Live audio level meter — visible proof that the mic is hot.
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
            .confirmationDialog(
                "Discard the previous recording? The audio will be permanently deleted.",
                isPresented: $showOrphanDiscardConfirm,
                titleVisibility: .visible
            ) {
                Button("Discard", role: .destructive) { vm.discardOrphan() }
                Button("Keep it", role: .cancel) {}
            }
        }
    }

    @ViewBuilder
    private func orphanCard(for orphan: PendingRecording) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text("Previous recording interrupted")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            Text("Your last session was interrupted (likely a phone call). The audio so far — \(orphanDurationLabel(orphan)) — is safe. What would you like to do?")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    vm.continueOrphan()
                } label: {
                    Label("Continue", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                        .font(.footnote.weight(.semibold))
                }
                Button {
                    vm.saveOrphan()
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.primary)
                        .font(.footnote.weight(.semibold))
                }
                Button {
                    showOrphanDiscardConfirm = true
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.red)
                        .font(.footnote.weight(.semibold))
                }
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal)
    }

    private func orphanDurationLabel(_ orphan: PendingRecording) -> String {
        let total = orphan.durationSeconds
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %dm %ds", h, m, s) }
        if m > 0 { return String(format: "%dm %ds", m, s) }
        return String(format: "%d seconds", s)
    }

    private var timerColor: Color {
        guard vm.isRecording else { return .primary }
        return vm.isPaused ? .secondary : .red
    }

    private var statusBadge: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(vm.isPaused ? Color.orange : Color.red)
                .frame(width: 10, height: 10)
                .opacity(vm.isPaused ? 1.0 : (vm.audioLevel > 0.05 ? 1.0 : 0.4))
                .animation(.easeInOut(duration: 0.4), value: vm.audioLevel > 0.05)
            Text(vm.isPaused ? "PAUSED" : "RECORDING")
                .font(.caption.weight(.semibold))
                .tracking(1.5)
                .foregroundStyle(vm.isPaused ? Color.orange : Color.red)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            (vm.isPaused ? Color.orange : Color.red).opacity(0.12),
            in: Capsule()
        )
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 24) {
                if vm.isRecording {
                    controlButton(
                        systemName: "trash.fill",
                        label: "Discard",
                        size: 64,
                        background: Color.gray.opacity(0.18),
                        foreground: .primary,
                        action: { showDiscardConfirm = true }
                    )

                    // The pause/resume control — visually the same size as Stop
                    // so it doesn't feel like a tucked-away minor action.
                    controlButton(
                        systemName: vm.isPaused ? "play.fill" : "pause.fill",
                        label: vm.isPaused ? "Resume" : "Pause",
                        size: 88,
                        background: vm.isPaused ? Color.green : Color.orange,
                        foreground: .white,
                        action: { vm.togglePause() }
                    )

                    controlButton(
                        systemName: "stop.fill",
                        label: "Stop & Save",
                        size: 88,
                        background: Color.red,
                        foreground: .white,
                        action: { vm.stopAndUpload() }
                    )
                } else {
                    VStack(spacing: 10) {
                        Button {
                            vm.startRecording()
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 38))
                                .foregroundStyle(.white)
                                .frame(width: 104, height: 104)
                                .background(Color.red, in: Circle())
                                .shadow(color: .red.opacity(0.35), radius: 14, x: 0, y: 6)
                        }
                        .accessibilityLabel("Start recording")
                        Text("Tap to record")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func controlButton(
        systemName: String,
        label: String,
        size: CGFloat,
        background: Color,
        foreground: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .foregroundStyle(foreground)
                    .frame(width: size, height: size)
                    .background(background, in: Circle())
            }
            .accessibilityLabel(label)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
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
