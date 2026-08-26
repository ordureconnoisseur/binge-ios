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

        Self.migrateSettingsKeys()

        Self.configureAudioSession()
    }

    // Without this iOS defaults to .soloAmbient / .ambient, which does
    // not reliably play audio with the screen locked or the ring switch
    // silenced, and can shift between app states.
    //
    // .playback      plays regardless of the ring switch and with the
    //                screen locked; the category for a video app.
    // .moviePlayback mode hint for the system.
    //
    // No .mixWithOthers. It was here so a Spotify soundtrack could keep
    // going "while watching binge muted (the default state)" - and mute
    // was removed in e26141a, so the premise went with it. What the
    // option costs is that a mixable session is not the primary audio
    // app: no Now Playing entry, no lock screen or Control Centre
    // transport, and the volume buttons are not unambiguously binge's.
    // A video app that always plays sound should own the session.
    private static func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[binge] audio session config failed: \(error)")
        }
    }

    /// Rename settings keys that drifted from the web plugin's, carrying
    /// the user's existing value across. binge and the web plugin
    /// deliberately share key names so a preference means the same thing
    /// on both clients (see AllowedGendersStore); these are the ones that
    /// got out of step. Runs before any @AppStorage view reads the key.
    private static func migrateSettingsKeys() {
        let defaults = UserDefaults.standard
        // `binge.profileStashDB` → `binge.includeStashDBInProfile`
        // (web's name). Only migrate when the new key is untouched, so a
        // value set since the rename always wins.
        let old = "binge.profileStashDB"
        let new = "binge.includeStashDBInProfile"
        if defaults.object(forKey: new) == nil,
            let legacy = defaults.object(forKey: old) as? Bool
        {
            defaults.set(legacy, forKey: new)
        }
        defaults.removeObject(forKey: old)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .task {
                    // Let Stash's plugin config supply the binge-server
                    // URL when the user hasn't set one — the loopback
                    // default is never the daemon on a phone.
                    await BingeServerService.ensureURLSeeded()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await MultiviewQueueStore.shared.refresh(force: true) }
                        // The session was configured once, at launch,
                        // and nothing ever put it back. A phone call,
                        // an alarm or Siri deactivates it, and every
                        // player from then on renders into a session
                        // that is not running - silent, with the app
                        // showing no sign of it and nothing short of a
                        // force quit to recover. setActive on an
                        // already-active session is a no-op, so this
                        // costs nothing in the normal case.
                        Self.configureAudioSession()
                    }
                }
        }
    }
}
