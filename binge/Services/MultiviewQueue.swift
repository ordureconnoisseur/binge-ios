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
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var loading = false

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

    /// One-shot load (idempotent). Buttons call this so the first reel/
    /// feed render that shows a multiview button populates the state.
    func loadIfNeeded() async {
        if loaded || loading { return }
        await reload()
    }

    func reload() async {
        if DemoMode.isOn { loaded = true; return }
        guard !baseURL.isEmpty else { return }
        loading = true
        defer { loading = false }
        do {
            let items = try await MultiviewService.fetchQueue(
                baseURL: baseURL, apiKey: apiKey
            )
            rawItems = items
            queuedIds = Set(items.compactMap { $0 as? String })
            loaded = true
        } catch {
            print("[binge] multiview queue load failed: \(error)")
        }
    }

    enum ToggleResult { case added, removed, full }

    /// Toggle a scene in the queue. Optimistic: the local set updates
    /// immediately (so the button flips without waiting on the network),
    /// then the write-through lands; a failed write rolls back + reloads.
    /// Adding at the 16-item cap is a no-op (.full) — the caller can
    /// surface a "queue full" message.
    @discardableResult
    func toggle(_ sceneId: String) async -> ToggleResult {
        let wasQueued = queuedIds.contains(sceneId)
        var items = rawItems
        let result: ToggleResult
        if wasQueued {
            items.removeAll { ($0 as? String) == sceneId }
            queuedIds.remove(sceneId)
            result = .removed
        } else {
            if items.count >= MultiviewService.maxQueue { return .full }
            items.append(sceneId)
            queuedIds.insert(sceneId)
            result = .added
        }
        rawItems = items
        if DemoMode.isOn { return result }
        do {
            try await MultiviewService.writeQueue(
                items, baseURL: baseURL, apiKey: apiKey
            )
        } catch {
            print("[binge] multiview queue write failed: \(error)")
            // Roll back the optimistic flip + resync from the server.
            if wasQueued {
                queuedIds.insert(sceneId)
            } else {
                queuedIds.remove(sceneId)
            }
            await reload()
        }
        return result
    }
}
