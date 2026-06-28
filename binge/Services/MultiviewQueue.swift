import Foundation
import SwiftUI

// Client + store for the Stash Multiview plugin's queue.
//
// The queue is the integration point between binge, the Multiview
// player, and the native multiview-ios app. On the WEB the queue lives
// in localStorage and the Multiview plugin mirrors it into Stash's
// plugin config (configuration.plugins.multiView.queue, a JSON string)
// so other surfaces can read it. iOS has neither localStorage nor that
// mirror, so binge writes the plugin config DIRECTLY — the same store
// multiview-ios reads (see multiview-ios QueueService).
//
// Queue items are either a scene-id string or a filter-slot object
// ({type:"filter", filter:{…}}). binge only ever toggles scene-id
// strings; filter slots are preserved untouched on write-back.
enum MultiviewService {
    // Mirrors the web's MULTIVIEW_MAX_QUEUE.
    static let maxQueue = 16

    /// Read the raw queue array from plugin config. Items are a mix of
    /// String (scene id) and [String: Any] (filter slot).
    static func fetchQueue(
        baseURL: String, apiKey: String
    ) async throws -> [Any] {
        struct Resp: Decodable {
            let configuration: Cfg
            struct Cfg: Decodable {
                let plugins: Plugins
                struct Plugins: Decodable {
                    let multiView: MV?
                    struct MV: Decodable { let queue: String? }
                }
            }
        }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let r: Resp = try await client.gql("{ configuration { plugins } }")
        let raw = r.configuration.plugins.multiView?.queue ?? "[]"
        guard let data = raw.data(using: .utf8),
            let arr = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return [] }
        return arr
    }

    /// Write the queue back via configurePlugin — identical mutation +
    /// shape to the web plugin's mirrorQueueToConfig.
    static func writeQueue(
        _ items: [Any], baseURL: String, apiKey: String
    ) async throws {
        let data = try JSONSerialization.data(withJSONObject: items)
        let json = String(decoding: data, as: UTF8.self)
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        // configurePlugin returns the plugin's config Map; we don't need
        // it, so decode into an empty struct (ignores all keys).
        struct Empty: Decodable {}
        let _: Empty = try await client.gql(
            "mutation($input: Map!) { configurePlugin(plugin_id: \"multiView\", input: $input) }",
            variables: ["input": ["queue": json]]
        )
    }
}

/// Observable singleton holding the current Multiview queue so the
/// reel/feed buttons render their queued state and survive cell remounts
/// (the same reason oCounter overrides live on the home VM). The set of
/// scene ids is observed; the full raw array (incl. filter slots) is kept
/// privately for write-back.
@Observable
@MainActor
final class MultiviewQueueStore {
    static let shared = MultiviewQueueStore()
    private init() {}

    /// Scene ids currently queued — drives every multiview button's
    /// filled/unfilled state.
    private(set) var queuedIds: Set<String> = []

    @ObservationIgnored private var rawItems: [Any] = []
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var lastLoadedAt: Date?
    /// In-flight optimistic toggle writes. A refresh while > 0 would
    /// risk reading a not-yet-committed server state and clobbering the
    /// optimistic value, so refresh() backs off until writes drain.
    @ObservationIgnored private var pendingWrites = 0

    /// Auto-refresh throttle. A surface (reel/feed) appearing re-syncs
    /// the queue, but not more often than this — so scrolling, which
    /// mounts many cells, doesn't spam the config query. A forced
    /// refresh (app foreground) bypasses it.
    private static let autoRefreshInterval: TimeInterval = 4

    private var baseURL: String {
        UserDefaults.standard.string(forKey: "binge.stashUrl") ?? ""
    }
    private var apiKey: String { KeychainStore.shared.stashApiKey }

    func isQueued(_ sceneId: String) -> Bool {
        queuedIds.contains(sceneId)
    }

    /// True when the queue is at the 16-item cap — a non-queued scene
    /// can't be added.
    var isFull: Bool { rawItems.count >= MultiviewService.maxQueue }

    /// Re-sync the queue from the server. Called when the reel/feed
    /// appears (throttled) and on app foreground (`force`). Skips while
    /// a write is in flight so it can't clobber an optimistic toggle,
    /// and skips a fresh-enough auto-refresh so scrolling doesn't spam
    /// Stash. This replaces the old once-only load — the queue can
    /// change from the web player or multiview-ios, so binge must keep
    /// re-reading it.
    func refresh(force: Bool = false) async {
        if DemoMode.isOn { return }
        if loading || pendingWrites > 0 { return }
        if !force, let t = lastLoadedAt,
            Date().timeIntervalSince(t) < Self.autoRefreshInterval
        {
            return
        }
        await reload()
    }

    private func reload() async {
        guard !baseURL.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let items = try await MultiviewService.fetchQueue(
                baseURL: baseURL, apiKey: apiKey
            )
            // A toggle may have started while we were awaiting the
            // fetch — don't overwrite the user's optimistic change with
            // a stale read.
            if pendingWrites > 0 { return }
            syncState(from: items)
        } catch {
            print("[binge] multiview queue load failed: \(error)")
        }
    }

    enum ToggleResult { case added, removed, full }

    /// Toggle a scene in the queue.
    ///
    /// CRITICAL: this is a READ-MODIFY-WRITE against the LIVE server
    /// queue, not a write of our local snapshot. The queue is shared
    /// with the web player and multiview-ios; writing a stale local copy
    /// would wipe scenes added/removed elsewhere (it did — an 8-item
    /// queue got clobbered down to 1). So we re-fetch, apply the user's
    /// intent (queued→remove, else add), and write that back.
    ///
    /// The local set flips optimistically first (instant button
    /// feedback), then reconciles to the server-consistent result. Intent
    /// comes from what the user SAW (the optimistic/visible state), so an
    /// add stays an add even if the scene turns out to already be on the
    /// server. Adding at the 16-item cap reverts and returns .full.
    @discardableResult
    func toggle(_ sceneId: String) async -> ToggleResult {
        let wantAdd = !queuedIds.contains(sceneId)
        // Optimistic flip for instant feedback.
        if wantAdd { queuedIds.insert(sceneId) } else { queuedIds.remove(sceneId) }

        if DemoMode.isOn {
            if wantAdd {
                if !(rawItems.contains { ($0 as? String) == sceneId }) {
                    rawItems.append(sceneId)
                }
            } else {
                rawItems.removeAll { ($0 as? String) == sceneId }
            }
            return wantAdd ? .added : .removed
        }

        pendingWrites += 1
        defer { pendingWrites -= 1 }
        do {
            var items = try await MultiviewService.fetchQueue(
                baseURL: baseURL, apiKey: apiKey
            )
            let present = items.contains { ($0 as? String) == sceneId }
            var changed = false
            if wantAdd, !present {
                if items.count >= MultiviewService.maxQueue {
                    // Server queue is full — revert the optimistic add and
                    // resync to the real (full) queue.
                    queuedIds.remove(sceneId)
                    syncState(from: items)
                    return .full
                }
                items.append(sceneId)
                changed = true
            } else if !wantAdd, present {
                items.removeAll { ($0 as? String) == sceneId }
                changed = true
            }
            if changed {
                try await MultiviewService.writeQueue(
                    items, baseURL: baseURL, apiKey: apiKey
                )
            }
            // Reconcile local state to the server-consistent queue — this
            // also surfaces scenes added elsewhere that we didn't know
            // about.
            syncState(from: items)
            return wantAdd ? .added : .removed
        } catch {
            print("[binge] multiview queue toggle failed: \(error)")
            // Revert the optimistic flip; leave the rest to the next refresh.
            if wantAdd { queuedIds.remove(sceneId) } else { queuedIds.insert(sceneId) }
            return wantAdd ? .removed : .added
        }
    }

    private func syncState(from items: [Any]) {
        rawItems = items
        queuedIds = Set(items.compactMap { $0 as? String })
        lastLoadedAt = Date()
    }

    /// Explicit user-driven re-sync (e.g. pull-to-refresh). Always
    /// re-reads, bypassing the throttle.
    func forceRefresh() async {
        await refresh(force: true)
    }
}
