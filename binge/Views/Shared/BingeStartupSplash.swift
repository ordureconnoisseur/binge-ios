import SwiftUI

/// Full-screen startup splash. Black background, centred animated
/// binge logo, nothing else — covers every other UI element
/// (toolbar, bottom nav, tab content) until the app has finished
/// its initial Stash handshake. Mirrors the web's
/// BingeStartupSplash so the two clients feel like the same
/// product at cold launch.
///
/// Dismissal gate: PluginContext.shared.loaded — set true once
/// the plugins-enumeration GraphQL query returns. That's the
/// canonical "Stash is reachable" handshake and a prerequisite
/// for everything else the app does.
///
/// Bounded by:
/// - MIN_HOLD_S gives a brand moment even when the plugin query
///   completes synchronously (warm cache).
/// - MAX_HOLD_S lets the user past the splash if Stash is
///   unreachable; underlying error states surface after.
struct BingeStartupSplash: View {
    private static let minHoldS: Double = 0.6
    private static let maxHoldS: Double = 4.5
    private static let fadeS: Double = 0.32

    @State private var minElapsed: Bool = false
    @State private var maxElapsed: Bool = false
    @State private var visible: Bool = true

    var body: some View {
        // Read PluginContext.shared.loaded in body so the
        // @Observable framework tracks reads and re-renders when
        // it flips. shouldDismiss combines all three gates.
        let pluginLoaded = PluginContext.shared.loaded
        let readyToFade =
            maxElapsed || (minElapsed && pluginLoaded)

        Group {
            if visible {
                ZStack {
                    Color.black.ignoresSafeArea()
                    BingeLoadingIcon()
                        .frame(width: 200, height: 200)
                }
                .opacity(readyToFade ? 0 : 1)
                .animation(
                    .easeOut(duration: Self.fadeS),
                    value: readyToFade
                )
                .allowsHitTesting(!readyToFade)
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(Self.minHoldS))
            minElapsed = true
        }
        .task {
            try? await Task.sleep(for: .seconds(Self.maxHoldS))
            maxElapsed = true
        }
        .onChange(of: readyToFade) { _, fade in
            // Once the fade transition finishes, fully unmount so
            // the splash isn't sitting invisible above the app
            // forever (small but unnecessary cost).
            if fade {
                Task {
                    try? await Task.sleep(for: .seconds(Self.fadeS))
                    visible = false
                }
            }
        }
    }
}
