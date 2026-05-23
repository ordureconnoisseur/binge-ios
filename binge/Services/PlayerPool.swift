import AVFoundation
import Foundation

// LRU cache of AVQueuePlayer instances keyed by scene id. Solves
// LazyVStack churn: when a slide unmounts its SceneSlideView's
// @State is lost, but its player stays alive HERE. When the user
// scrolls back, the pool returns the same warm player — instant
// playback, no re-buffer.
//
// Capacity 5 — bigger than LazyVStack's typical mount window so a
// currently-mounted slide always finds its cached player. Below
// iOS's ~4 concurrent H.264 hardware decoders since only the
// active player decodes; others sit paused.
//
// Looping is via AVPlayerLooper. We briefly tried manual-loop via
// AVPlayerItemDidPlayToEndTime notification observers — five
// pool entries each firing their own seek-to-zero callback turned
// out to be enough to push the iOS media-services XPC daemon into
// AVErrorMediaServicesWereReset (-12860), which broke EVERY scene
// in the reel, not just the one being looped. AVPlayerLooper
// handles looping at the AVFoundation layer where it belongs.
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

    /// Get a player for this scene. Cache hit refreshes lastUsed
    /// + returns the existing player. Cache miss creates a new
    /// player (and evicts the LRU entry if we'd exceed capacity).
    /// Returns nil only when the scene has no stream URL.
    func player(
        for scene: BingeScene,
        baseURL: String,
        apiKey: String,
        muted: Bool
    ) -> AVPlayer? {
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
        let q = AVQueuePlayer(playerItem: item)
        q.isMuted = muted
        // AVPlayerLooper queues a second item internally for
        // seamless looping. Slightly more memory than manual seek
        // but the media services overhead of N concurrent
        // .AVPlayerItemDidPlayToEndTime observers (the alternative)
        // is more disruptive than the duplicate item.
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

    /// Pause every player in the pool.
    func pauseAll() {
        for (_, entry) in entries { entry.player.pause() }
    }

    /// Drain the pool, keeping only the listed scene ids.
    func evictExcept(keepers: Set<String>) {
        for (id, entry) in entries where !keepers.contains(id) {
            entry.player.pause()
            entry.player.replaceCurrentItem(with: nil)
            entries.removeValue(forKey: id)
        }
    }

    /// Diagnostic — current pool depth.
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
