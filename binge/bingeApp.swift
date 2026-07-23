import AVFoundation
import SwiftUI

// App entry — single SwiftUI scene. The first surface a user sees is
// either RootView (if Stash credentials are set) or SettingsView
// (first-launch, captures URL + API key). The branch lives in
// RootView itself to keep this entry trivially short.
@main
struct BingeApp: App {
    // Re-sync the Multiview queue whenever the app returns to the
    // foreground — the queue can change from the web player or
    // multiview-ios while binge is backgrounded, and a warm resume
    // would otherwise keep showing the stale set.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Restore the Stash URL from its Keychain mirror before
        // RootView decides between the setup screen and the app.
        // UserDefaults is wiped by an app reinstall; the Keychain
        // isn't, so this keeps a redeploy from logging the user out
        // of their own server.
        KeychainStore.syncStashUrlBackup()

        // Configure the audio session once at launch. Without this
        // call iOS defaults to .soloAmbient / .ambient which
        // doesn't reliably play audio when the device is locked
        // or in silent mode, and the category can shift unexpectedly
        // between app states.
        //
        // .playback         — plays even when device is muted /
        //                     screen is locked; right category
        //                     for a video app.
        // .moviePlayback    — mode hint for the system.
        // .mixWithOthers    — doesn't interrupt Music/Spotify. The
        //                     user can keep their soundtrack going
        //                     while watching binge muted (the
        //                     default state) — and if they unmute,
        //                     both play simultaneously (same as
        //                     Instagram, not iOS Music ducking).
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[binge] audio session config failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await MultiviewQueueStore.shared.refresh(force: true) }
                    }
                }
        }
    }
}
