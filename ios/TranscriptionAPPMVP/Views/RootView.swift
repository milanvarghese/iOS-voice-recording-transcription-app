import SwiftUI

struct RootView: View {
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
        case .signedOut, .awaitingOTP:
            AuthView()
        case .signedIn:
            MainTabView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            RecordingView()
                .tabItem { Label("Record", systemImage: "mic.circle.fill") }
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var auth: AuthViewModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(role: .destructive) {
                        Task { await auth.signOut() }
                    } label: {
                        Text("Sign out")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
