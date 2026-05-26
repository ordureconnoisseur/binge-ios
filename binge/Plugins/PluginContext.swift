import SwiftUI

// Tracks which Stash plugins are installed AND enabled. Mirrors
// the web's src/plugins/PluginContext.tsx — binge gates plugin-
// coupled UI (advanced rating, multiview, scribe, …) on a
// matching id appearing in the installed list with `enabled: true`.
//
// Stash's root `plugins { id enabled }` returns every installed
// plugin with its enabled flag. We treat "disabled" the same as
// "not installed" — a disabled plugin's UI affordances in binge
// should disappear too (the user can re-enable in Stash to bring
// them back).
//
// Singleton `@Observable` shared across the app. First view that
// reads it triggers the fetch; subsequent reads use the cached
// result. Failures are silent — empty list, all gates stay closed.

/// Plugin ids binge integrates with. Defined here so call sites
/// and detection logic reference the same constants.
enum PluginID {
    static let advancedRating = "advancedRating"
    static let multiView = "multiView"
    static let scribe = "stashScribe"
}

@Observable
@MainActor
final class PluginContext {
    static let shared = PluginContext()

    /// True once the fetch returned (success OR failure). UI can
    /// either render conservatively (hide gated buttons) until
    /// loaded, or treat `!loaded` as "unknown" and skip
    /// gating.
    var loaded: Bool = false
    /// Plugin ids that are installed AND enabled.
    private var enabledIds: Set<String> = []

    private var fetching: Bool = false

    private init() {}

    func hasPlugin(_ id: String) -> Bool {
        enabledIds.contains(id)
    }

    /// Convenience for the advanced rating gate.
    var hasAdvancedRating: Bool {
        hasPlugin(PluginID.advancedRating)
    }

    /// One-shot fetch. Idempotent — concurrent callers see the
    /// in-flight `fetching` guard and the already-loaded short-
    /// circuit. Re-callable after `invalidate()` for a refresh
    /// (e.g. when the user toggles a plugin in Stash mid-session,
    /// though we don't auto-detect that yet).
    func load(baseURL: String, apiKey: String) async {
        if loaded || fetching { return }
        fetching = true
        defer { fetching = false }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: InstalledPluginsResponse = try await client.gql(
                Queries.installedPlugins,
                variables: [:]
            )
            enabledIds = Set(
                resp.plugins.filter(\.enabled).map(\.id)
            )
        } catch {
            print("[binge] plugin detection failed: \(error)")
            enabledIds = []
        }
        loaded = true
    }

    func invalidate() {
        enabledIds = []
        loaded = false
    }
}
