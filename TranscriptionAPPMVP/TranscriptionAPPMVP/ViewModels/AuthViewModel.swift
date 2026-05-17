import Foundation
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    enum State {
        case loading
        case signedOut
        case awaitingOTP(email: String)
        case signedIn(userId: UUID)
    }

    @Published var state: State = .loading
    @Published var errorMessage: String?
    @Published var isWorking = false

    func restoreSession() async {
        // supabase-swift persists the session locally; check if we already have one.
        if let userId = SupabaseService.shared.currentUserId {
            state = .signedIn(userId: userId)
        } else {
            state = .signedOut
        }
    }

    func sendCode(to email: String) async {
        guard !email.isEmpty else {
            errorMessage = "Enter your email."
            return
        }
        isWorking = true
        errorMessage = nil
        do {
            try await SupabaseService.shared.sendOTP(email: email)
            state = .awaitingOTP(email: email)
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func verify(code: String) async {
        guard case .awaitingOTP(let email) = state else { return }
        isWorking = true
        errorMessage = nil
        do {
            try await SupabaseService.shared.verifyOTP(email: email, code: code)
            if let userId = SupabaseService.shared.currentUserId {
                state = .signedIn(userId: userId)
            }
        } catch {
            errorMessage = "Wrong code. Try again."
        }
        isWorking = false
    }

    func resendCode() async {
        guard case .awaitingOTP(let email) = state else { return }
        await sendCode(to: email)
    }

    func signOut() async {
        try? await SupabaseService.shared.signOut()
        state = .signedOut
    }
}
