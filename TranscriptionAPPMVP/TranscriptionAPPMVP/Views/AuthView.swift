import SwiftUI

struct AuthView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var email = ""
    @State private var code = ""
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    // Locked color values so the screen never inverts under system dark mode.
    private let bgTop = Color(red: 0.06, green: 0.08, blue: 0.14)
    private let bgBottom = Color(red: 0.10, green: 0.05, blue: 0.18)
    private let inputBackground = Color(red: 0.14, green: 0.16, blue: 0.22)
    private let inputBorder = Color.white.opacity(0.12)
    private let inputBorderActive = Color(red: 0.55, green: 0.45, blue: 1.00)
    private let primaryText = Color(red: 0.96, green: 0.97, blue: 1.00)
    private let secondaryText = Color(red: 0.65, green: 0.69, blue: 0.80)
    private let tertiaryText = Color(red: 0.45, green: 0.48, blue: 0.58)
    private let accentStart = Color(red: 0.42, green: 0.45, blue: 1.00)
    private let accentEnd = Color(red: 0.78, green: 0.40, blue: 1.00)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [bgTop, bgBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Faint radial highlight to add depth without affecting contrast.
            RadialGradient(
                colors: [Color.white.opacity(0.06), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 10) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 84, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [accentStart, accentEnd],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: accentEnd.opacity(0.35), radius: 18, x: 0, y: 8)
                        .padding(.bottom, 8)

                    Text("TranscriptionAPPMVP")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .foregroundStyle(primaryText)
                        .multilineTextAlignment(.center)

                    Text("Record. Transcribe. Extract.")
                        .font(.callout)
                        .foregroundStyle(secondaryText)
                }
                .padding(.bottom, 40)

                Group {
                    switch auth.state {
                    case .signedOut, .loading:
                        emailEntry
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    case .awaitingOTP(let email):
                        codeEntry(email: email)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    case .signedIn:
                        EmptyView()
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: stateID)

                if let error = auth.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                        .padding(.horizontal)
                }

                Spacer()
                Spacer()

                VStack(spacing: 2) {
                    Text("Developed by Milan Varghese")
                        .font(.caption2)
                        .foregroundStyle(tertiaryText)
                    Text("milanvarghese99@gmail.com")
                        .font(.caption2)
                        .foregroundStyle(tertiaryText)
                }
                .padding(.bottom, 20)
            }
            .padding(.horizontal, 28)
        }
        .preferredColorScheme(.dark)   // keep keyboard/cursor tinting consistent
    }

    private var stateID: String {
        switch auth.state {
        case .signedOut, .loading: return "email"
        case .awaitingOTP: return "otp"
        case .signedIn: return "in"
        }
    }

    private var emailEntry: some View {
        VStack(spacing: 14) {
            Text("Sign in with your email")
                .font(.subheadline)
                .foregroundStyle(secondaryText)

            TextField("", text: $email, prompt: Text("you@example.com").foregroundColor(tertiaryText))
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($emailFocused)
                .foregroundStyle(primaryText)
                .tint(accentEnd)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(inputBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(emailFocused ? inputBorderActive : inputBorder,
                                      lineWidth: emailFocused ? 1.5 : 1)
                )
                .submitLabel(.send)
                .onSubmit { send() }

            primaryButton(title: "Send code", action: send,
                          enabled: !auth.isWorking && !email.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func codeEntry(email: String) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Check your email")
                    .font(.subheadline)
                    .foregroundStyle(secondaryText)
                Text(email)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(primaryText)
            }

            TextField("", text: $code, prompt: Text("123456").foregroundColor(tertiaryText))
                .keyboardType(.numberPad)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .multilineTextAlignment(.center)
                .focused($codeFocused)
                .foregroundStyle(primaryText)
                .tint(accentEnd)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(inputBackground, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(codeFocused ? inputBorderActive : inputBorder,
                                      lineWidth: codeFocused ? 1.5 : 1)
                )

            primaryButton(title: "Verify", action: verify,
                          enabled: !auth.isWorking && code.count >= 6)

            HStack {
                Button("Resend code") {
                    Task { await auth.resendCode() }
                }
                .foregroundStyle(secondaryText)
                Spacer()
                Button("Change email") {
                    code = ""
                    Task { await auth.signOut() }
                }
                .foregroundStyle(secondaryText)
            }
            .font(.footnote)
            .padding(.top, 4)
        }
        .onAppear { codeFocused = true }
    }

    @ViewBuilder
    private func primaryButton(title: String, action: @escaping () -> Void, enabled: Bool) -> some View {
        Button(action: action) {
            HStack {
                if auth.isWorking {
                    ProgressView().tint(.white)
                } else {
                    Text(title).fontWeight(.semibold)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [accentStart, accentEnd],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .foregroundStyle(.white)
            .shadow(color: accentEnd.opacity(0.4), radius: 12, x: 0, y: 6)
            .opacity(enabled ? 1.0 : 0.5)
        }
        .disabled(!enabled)
    }

    private func send() {
        Task { await auth.sendCode(to: email.trimmingCharacters(in: .whitespaces)) }
    }

    private func verify() {
        Task { await auth.verify(code: code.trimmingCharacters(in: .whitespaces)) }
    }
}
