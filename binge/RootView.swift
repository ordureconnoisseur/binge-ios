import SwiftUI

// Root branch: not-yet-configured → SettingsView in setup mode;
// configured → main TabView with Home / Reel / Profile / Settings.
//
// "Configured" means both a Stash URL and an API key exist in
// UserDefaults (the @AppStorage keys SettingsView writes). Wiring is
// simple in v0.1 — once the user's pasted creds and the
// connection probe succeeds, the body re-renders into the main shell.
struct RootView: View {
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    @AppStorage("binge.stashApiKey") private var stashApiKey: String = ""

    var body: some View {
        if stashUrl.isEmpty || stashApiKey.isEmpty {
            SettingsView(mode: .setup)
        } else {
            MainShell()
        }
    }
}

// v0.1 = reel + settings only. Home / profile / discovery land in
// later versions once we've validated that native AVPlayer + paged
// TabView actually feel meaningfully smoother than the web app.
private struct MainShell: View {
    var body: some View {
        TabView {
            ReelView()
                .tabItem { Label("For You", systemImage: "play.square") }

            SettingsView(mode: .normal)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.white)
    }
}
