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

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }

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

                Section("About") {
                    HStack {
                        Text("App")
                        Spacer()
                        Text("TranscriptionAPPMVP").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(appVersion).foregroundStyle(.secondary).monospacedDigit()
                    }
                    HStack {
                        Text("Developed by")
                        Spacer()
                        Text("Milan Varghese").foregroundStyle(.secondary)
                    }
                    if let url = URL(string: "mailto:milanvarghese99@gmail.com") {
                        Link(destination: url) {
                            HStack {
                                Text("Contact").foregroundStyle(.primary)
                                Spacer()
                                Text("milanvarghese99@gmail.com").foregroundStyle(.secondary)
                                Image(systemName: "envelope").foregroundStyle(.secondary).font(.footnote)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
