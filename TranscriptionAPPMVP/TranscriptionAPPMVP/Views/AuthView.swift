import SwiftUI

struct AuthView: View {
    @EnvironmentObject var auth: AuthViewModel
    @State private var email = ""
    @State private var code = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "waveform")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.tint)
                Text("TranscriptionAPPMVP")
                    .font(.title.bold())

                switch auth.state {
                case .signedOut, .loading:
                    emailEntry
                case .awaitingOTP(let email):
                    codeEntry(email: email)
                case .signedIn:
                    EmptyView()
                }

                if let error = auth.errorMessage {
                    Text(error).foregroundStyle(.red).font(.footnote)
                }
                Spacer()
            }
            .padding()
        }
    }

    private var emailEntry: some View {
        VStack(spacing: 16) {
            Text("Sign in with your email. We'll send you a 6-digit code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("you@example.com", text: $email)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Button {
                Task { await auth.sendCode(to: email.trimmingCharacters(in: .whitespaces)) }
            } label: {
                if auth.isWorking { ProgressView() }
                else { Text("Send code").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(auth.isWorking)
        }
    }

    private func codeEntry(email: String) -> some View {
        VStack(spacing: 16) {
            Text("Check **\(email)** for a 6-digit code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
            Button {
                Task { await auth.verify(code: code.trimmingCharacters(in: .whitespaces)) }
            } label: {
                if auth.isWorking { ProgressView() }
                else { Text("Verify").frame(maxWidth: .infinity) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(auth.isWorking || code.count < 6)

            Button("Resend code") {
                Task { await auth.resendCode() }
            }
            .font(.footnote)
        }
    }
}
