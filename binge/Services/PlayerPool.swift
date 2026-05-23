import AVFoundation
import Foundation

// LRU cache of AVQueuePlayer instances keyed by scene id. Solves
// the LazyVStack churn problem: when a slide unmounts (scrolls out
// of LazyVStack's window) its SceneSlideView's @State is lost, but
// its player stays alive HERE. When the user scrolls back, the
// pool returns the same warm player — instant playback, no
// re-buffer.
//
// Capacity is set to 5 — bigger than LazyVStack's typical mount
// window (~3-5 slides) so any slide currently mounted always has
// its player cached, plus a couple of extra slots for recently-
// visited scenes. Below iOS's hardware H.264 decoder budget (~4
// concurrent) since only the active player is actually decoding;
// the others are paused-but-cached.
//
// Replaces the earlier PlayerRegistry, which was a passive weak
// set with no lifecycle management. The pool actively owns + evicts.
@MainActor
final class PlayerPool {
    static let shared = PlayerPool(capacity: 5)

    private struct Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        var lastUsed: Date
    }

    private var entries: [String: Entry] = [:]
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    /// Get a player for this scene. Cache hit refreshes lastUsed +
    /// returns the existing player. Cache miss creates a new
    /// player (and evicts the LRU entry if we'd exceed capacity).
    /// Returns nil only when the scene has no stream URL.
    func player(
        for scene: BingeScene,
        baseURL: String,
        apiKey: String,
        muted: Bool
    ) -> AVQueuePlayer? {
        if var entry = entries[scene.id] {
            entry.lastUsed = Date()
            entries[scene.id] = entry
            entry.player.isMuted = muted
            return entry.player
        }
        guard let url = scene.streamURL(base: baseURL) else { return nil }
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["ApiKey": apiKey]
            ]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4.0
        let q = AVQueuePlayer(playerItem: item)
        q.isMuted = muted
        let looper = AVPlayerLooper(player: q, templateItem: item)
        entries[scene.id] = Entry(
            player: q,
            looper: looper,
            lastUsed: Date()
        )
        evictIfNeeded()
        return q
    }

    /// Refresh lastUsed for a scene without touching the player.
    /// Used when a slide re-appears via LazyVStack remount — keeps
    /// the entry from being evicted just because the user is
    /// looking at it.
    func touch(sceneId: String) {
        if var entry = entries[sceneId] {
            entry.lastUsed = Date()
            entries[sceneId] = entry
        }
    }

    /// Pause every player in the pool. Used by a future
    /// onScrollPhaseChange hook (iOS 18+) or when the reel tab
    /// loses focus. The active slide can call .play() again when
    /// it's ready — pause is non-destructive (no buffer flush).
    func pauseAll() {
        for (_, entry) in entries { entry.player.pause() }
    }

    /// Drain the pool, keeping only the listed scene ids. Used
    /// when the user navigates away from the reel entirely so we
    /// don't keep evicted scene assets warm forever. Pass an
    /// empty set to drain completely.
    func evictExcept(keepers: Set<String>) {
        for (id, entry) in entries where !keepers.contains(id) {
            entry.player.pause()
            entry.player.replaceCurrentItem(with: nil)
            entries.removeValue(forKey: id)
        }
    }

    /// Diagnostic — current pool depth. Useful for spot-checking
    /// in the debugger when investigating decoder pressure.
    var count: Int { entries.count }

    private func evictIfNeeded() {
        while entries.count > capacity {
            guard
                let oldest = entries.min(by: {
                    $0.value.lastUsed < $1.value.lastUsed
                })
            else { return }
            oldest.value.player.pause()
            oldest.value.player.replaceCurrentItem(with: nil)
            entries.removeValue(forKey: oldest.key)
        }
    }
}
