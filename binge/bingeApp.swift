import SwiftUI

// App entry — single SwiftUI scene. The first surface a user sees is
// either RootView (if Stash credentials are set) or SettingsView
// (first-launch, captures URL + API key). The branch lives in
// RootView itself to keep this entry trivially short.
@main
struct BingeApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
