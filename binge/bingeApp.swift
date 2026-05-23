import AVFoundation
import SwiftUI

// App entry — single SwiftUI scene. The first surface a user sees is
// either RootView (if Stash credentials are set) or SettingsView
// (first-launch, captures URL + API key). The branch lives in
// RootView itself to keep this entry trivially short.
@main
struct BingeApp: App {
    init() {
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
        //                     TikTok, not iOS Music ducking).
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
        }
    }
}
