import AVFoundation
import Foundation

// LRU cache of AVPlayer instances keyed by scene id. Solves
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
// Looping: AVPlayerItemDidPlayToEndTime + seek-to-zero. Earlier
// version used AVPlayerLooper which queues a duplicate item — half
// the memory savings come from dropping that.
@MainActor
final class PlayerPool {
    static let shared = PlayerPool(capacity: 5)

    private struct Entry {
        let player: AVPlayer
        let endObserver: NSObjectProtocol
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
        item.preferredForwardBufferDuration = 4.0
        let player = AVPlayer(playerItem: item)
        player.isMuted = muted
        // Manual loop: seek to zero + resume when the current item
        // finishes. The notification's `object` is the SPECIFIC
        // item — so this observer only fires for this player's
        // item, not any other player's. weak player so we don't
        // leak the player via the observer block.
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        entries[scene.id] = Entry(
            player: player,
            endObserver: observer,
            lastUsed: Date()
        )
        evictIfNeeded()
        return player
    }

    /// Same as player(for:) but ignores the return value — used by
    /// ReelView to proactively warm upcoming scenes when activeId
    /// changes, so the next swipe is a cache hit instead of a
    /// cold load. The pool retains the entry; the next caller
    /// (the slide's onAppear) finds it warm.
    func prewarm(
        scene: BingeScene,
        baseURL: String,
        apiKey: String,
        muted: Bool
    ) {
        _ = player(
            for: scene,
            baseURL: baseURL,
            apiKey: apiKey,
            muted: muted
        )
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

    /// Drain the pool, keeping only the listed scene ids. Used
    /// when the user navigates away from the reel entirely.
    func evictExcept(keepers: Set<String>) {
        for (id, entry) in entries where !keepers.contains(id) {
            tearDown(entry: entry)
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
            tearDown(entry: oldest.value)
            entries.removeValue(forKey: oldest.key)
        }
    }

    private func tearDown(entry: Entry) {
        NotificationCenter.default.removeObserver(entry.endObserver)
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
    }
}
