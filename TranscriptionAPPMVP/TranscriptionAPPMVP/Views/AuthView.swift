import SwiftUI

struct AuthView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var email = ""
    @State private var code = ""
    @FocusState private var emailFocused: Bool
    @FocusState private var codeFocused: Bool

    var body: some View {
        ZStack {
            // Soft accent gradient background. Subtle, not distracting.
            LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.96, blue: 1.00),
                    Color(red: 0.88, green: 0.91, blue: 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 84, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.accentColor, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .accentColor.opacity(0.25), radius: 16, x: 0, y: 8)
                        .padding(.bottom, 12)

                    Text("TranscriptionAPPMVP")
                        .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        .multilineTextAlignment(.center)

                    Text("Record. Transcribe. Extract.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 36)

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
                        .foregroundStyle(.tertiary)
                    Text("milanvarghese99@gmail.com")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 28)
        }
    }

    /// Drives the slide/fade transition between the email and OTP cards.
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
                .foregroundStyle(.secondary)

            TextField("you@example.com", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($emailFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(emailFocused ? Color.accentColor : Color.black.opacity(0.08),
                                      lineWidth: emailFocused ? 1.5 : 1)
                )
                .submitLabel(.send)
                .onSubmit { send() }

            Button(action: send) {
                HStack {
                    if auth.isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Send code").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(.white)
                .shadow(color: .accentColor.opacity(0.3), radius: 10, x: 0, y: 4)
            }
            .disabled(auth.isWorking || email.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func codeEntry(email: String) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("Check your email")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(email)
                    .font(.callout.weight(.medium))
            }

            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .font(.system(.title2, design: .monospaced).weight(.semibold))
                .multilineTextAlignment(.center)
                .focused($codeFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(codeFocused ? Color.accentColor : Color.black.opacity(0.08),
                                      lineWidth: codeFocused ? 1.5 : 1)
                )

            Button(action: verify) {
                HStack {
                    if auth.isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text("Verify").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(.white)
                .shadow(color: .accentColor.opacity(0.3), radius: 10, x: 0, y: 4)
            }
            .disabled(auth.isWorking || code.count < 6)

            HStack {
                Button("Resend code") {
                    Task { await auth.resendCode() }
                }
                Spacer()
                Button("Change email") {
                    code = ""
                    Task { await auth.signOut() }   // returns us to .signedOut
                }
            }
            .font(.footnote)
            .padding(.top, 4)
        }
        .onAppear {
            codeFocused = true
        }
    }

    private func send() {
        Task {
            await auth.sendCode(to: email.trimmingCharacters(in: .whitespaces))
        }
    }

    private func verify() {
        Task {
            await auth.verify(code: code.trimmingCharacters(in: .whitespaces))
        }
    }
}
