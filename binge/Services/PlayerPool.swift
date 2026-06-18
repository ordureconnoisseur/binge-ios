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
    // Capacity 3 — dropped from 5 after observing recurring
    // -12785 / -12860 media-services-reset errors over the user's
    // remote Stash link. 5 concurrent players + their network
    // connections were contending too aggressively for the
    // PlayerRemoteXPC service's resources. 3 covers the active
    // slide + one prefetched + one recently-visited cache slot,
    // which is enough to feel snappy without overloading the
    // network or decoder budget.
    static let shared = PlayerPool(capacity: 3)

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
        muted: Bool,
        // When set, build the player against THIS url instead of
        // the scene's computed streamURL, and bypass the cache so a
        // stale entry isn't returned. Used by SceneSlideView's
        // direct->HLS fallback for non-faststart HEVC that stalls
        // on direct play. The caller evicts the old entry first.
        overrideURL: URL? = nil
    ) -> AVPlayer? {
        if overrideURL == nil, var entry = entries[scene.id] {
            entry.lastUsed = Date()
            entries[scene.id] = entry
            entry.player.isMuted = muted
            print(
                "[PlayerPool] HIT  scene=\(scene.id) "
                + "pool=\(entries.count)/\(capacity)"
            )
            return entry.player
        }
        let createStart = Date()
        guard let url = overrideURL ?? scene.streamURL(base: baseURL)
        else {
            print(
                "[PlayerPool] MISS scene=\(scene.id) -> no streamURL"
            )
            return nil
        }
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["ApiKey": apiKey]
            ]
        )
        let item = AVPlayerItem(asset: asset)
        // Tune for first-frame speed: AVPlayer defaults to ~25s
        // forward buffer + wait-to-minimize-stalling which adds
        // 1-2s of pre-roll over the user's Tailscale-funnel
        // link. 2s buffer + don't-wait gets playback going
        // ~5× faster. These knobs are independent of the
        // loop / playback-stall recovery logic — reverting
        // those didn't require touching buffer settings.
        item.preferredForwardBufferDuration = 2
        let q = AVQueuePlayer(playerItem: item)
        q.automaticallyWaitsToMinimizeStalling = false
        q.isMuted = muted
        // AVPlayerLooper queues a second item internally for
        // seamless looping. Slightly more memory than manual
        // seek-to-zero but the media services overhead of N
        // concurrent .AVPlayerItemDidPlayToEndTime observers
        // (the alternative) is more disruptive than the
        // duplicate item.
        let looper = AVPlayerLooper(player: q, templateItem: item)
        entries[scene.id] = Entry(
            player: q,
            looper: looper,
            lastUsed: Date()
        )
        evictIfNeeded()
        let ms = Int(Date().timeIntervalSince(createStart) * 1000)
        print(
            "[PlayerPool] MISS scene=\(scene.id) "
            + "create=\(ms)ms pool=\(entries.count)/\(capacity) "
            + "url=\(url.absoluteString.prefix(80))"
        )
        // Surface buffer-ready timing too — the actual "video
        // appears" moment depends on the asset's first frame
        // being decoded, which can be much later than the
        // synchronous AVPlayer creation above.
        let scheduledStart = Date()
        let sceneId = scene.id
        Task { @MainActor in
            // Loose poll for buffer-likely-to-keep-up — cheap
            // and avoids KVO complications. Reports the first
            // time the player has any buffered output.
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(50))
                if q.currentItem?.isPlaybackLikelyToKeepUp == true {
                    let pms = Int(
                        Date().timeIntervalSince(scheduledStart)
                            * 1000
                    )
                    print(
                        "[PlayerPool] READY scene=\(sceneId) "
                        + "after=\(pms)ms"
                    )
                    return
                }
            }
            print(
                "[PlayerPool] SLOW scene=\(sceneId) "
                + "still not ready after 3s"
            )
        }
        return q
    }

    /// Eagerly fetch the player for a scene without playing it.
    /// Called by ReelView when activeId advances, so the next
    /// scene is already buffered when the user swipes to it.
    /// Conservative — single step ahead only, to keep the pool
    /// inside its capacity and avoid the PlayerRemoteXPC reset
    /// storm that the earlier 2-step + cap-5 setup triggered.
    func prewarm(
        scene: BingeScene,
        baseURL: String,
        apiKey: String,
        muted: Bool
    ) {
        // Same code path as `player(for:)` — the side effect of
        // creating + caching the AVPlayer is what we want.
        _ = player(
            for: scene,
            baseURL: baseURL,
            apiKey: apiKey,
            muted: muted
        )
    }

    /// Drop a single scene's player entry — used by
    /// SceneSlideView when AVPlayer reports `.failed`, so the
    /// next attachPlayer() call gets a fresh player instead of
    /// returning the failed one from cache. Without this, the
    /// "forward-then-back makes it play" pattern is the only
    /// recovery path the user has.
    func evict(sceneId: String) {
        guard let entry = entries[sceneId] else { return }
        entry.player.pause()
        entry.player.replaceCurrentItem(with: nil)
        entries.removeValue(forKey: sceneId)
        print(
            "[PlayerPool] EVICT scene=\(sceneId) reason=manual "
            + "pool=\(entries.count)/\(capacity)"
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
            print(
                "[PlayerPool] EVICT scene=\(oldest.key) "
                + "pool=\(entries.count)/\(capacity)"
            )
        }
    }
}
