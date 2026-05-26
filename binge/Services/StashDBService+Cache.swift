import Foundation

// Read-through caches for the StashDB-side fetches. Call sites
// switch from `service.fetchX()` to `service.cachedX()` to get
// the disk-backed cached value (or a fresh fetch on miss).
//
// Memory layer first (NSLock-guarded dict on the cache singleton)
// then disk (UserDefaults JSON), then network. Misses warm both
// layers.
//
// Invalidation pattern:
//   - `StashDBCache.shared.invalidateAll()` — pull-to-refresh
//     blows the whole disk cache + in-memory shadow.
//   - `StashDBCache.shared.invalidate(prefix: "linked")` — kill
//     the linked-performers shadow after a Follow.
//
// Note: `fetchBoxConfig` returns the same StashBoxConfig
// regardless of who calls it, so the cache key is fixed.
// `fetchNewScenes` is keyed by `sinceDate` (the lookback window)
// — different windows return different scene sets.
extension StashDBService {
    func cachedBoxConfig() async -> StashBoxConfig? {
        let key = "box"
        if let cached: StashBoxConfig = StashDBCache.shared.memoRead(key) {
            return cached
        }
        if let cached: StashBoxConfig = StashDBCache.shared.read(
            key, ttl: StashDBCache.TTL.stashBox
        ) {
            StashDBCache.shared.memoWrite(key, value: cached)
            return cached
        }
        let fresh = await fetchBoxConfig()
        if let fresh {
            StashDBCache.shared.write(key, value: fresh)
            StashDBCache.shared.memoWrite(key, value: fresh)
        }
        return fresh
    }

    func cachedLinkedPerformers() async -> [LinkedPerformer] {
        let key = "linked"
        if let cached: [LinkedPerformer] = StashDBCache.shared.memoRead(
            key
        ) {
            return cached
        }
        if let cached: [LinkedPerformer] = StashDBCache.shared.read(
            key, ttl: StashDBCache.TTL.ownership
        ) {
            StashDBCache.shared.memoWrite(key, value: cached)
            return cached
        }
        let fresh = await fetchLinkedPerformers()
        StashDBCache.shared.write(key, value: fresh)
        StashDBCache.shared.memoWrite(key, value: fresh)
        return fresh
    }

    func cachedOwnedStashIds() async -> Set<String> {
        let key = "owned"
        if let cached: [String] = StashDBCache.shared.memoRead(key) {
            return Set(cached)
        }
        if let cached: [String] = StashDBCache.shared.read(
            key, ttl: StashDBCache.TTL.ownership
        ) {
            StashDBCache.shared.memoWrite(key, value: cached)
            return Set(cached)
        }
        let fresh = await fetchOwnedStashIds()
        let asArray = Array(fresh)
        StashDBCache.shared.write(key, value: asArray)
        StashDBCache.shared.memoWrite(key, value: asArray)
        return fresh
    }

    func cachedTrendingScenes(
        apiKey stashDBKey: String
    ) async -> [StashDBScene] {
        let key = "trendingScenes"
        if let cached: [StashDBScene.Snapshot] =
            StashDBCache.shared.memoRead(key)
        {
            return cached.map(StashDBScene.init)
        }
        if let snaps: [StashDBScene.Snapshot] = StashDBCache.shared.read(
            key, ttl: StashDBCache.TTL.trending
        ) {
            StashDBCache.shared.memoWrite(key, value: snaps)
            return snaps.map(StashDBScene.init)
        }
        let fresh = await fetchTrendingScenes(apiKey: stashDBKey)
        let snaps = fresh.map(\.snapshot)
        // Don't write empty arrays to disk — empty here almost
        // always means a transient network / GraphQL failure, and
        // we don't want to pin "no trending scenes" for 12h.
        // Empty IS technically a valid response from StashDB, but
        // for surfaces this prominent the false-negative cost of
        // pinning empty far outweighs the cost of one re-fetch
        // next session.
        if !fresh.isEmpty {
            StashDBCache.shared.write(key, value: snaps)
            StashDBCache.shared.memoWrite(key, value: snaps)
        }
        return fresh
    }

    func cachedNewScenes(
        performerStashIds: [String],
        sinceDate: String,
        apiKey stashDBKey: String
    ) async -> [StashDBScene] {
        // Key on sinceDate — different lookback windows return
        // disjoint scene sets. The linked-performer list is
        // captured implicitly: if it changes (via Follow),
        // invalidation prefix `linked` cleans us up too.
        let key = "newScenes:\(sinceDate)"
        if let cached: [StashDBScene.Snapshot] =
            StashDBCache.shared.memoRead(key)
        {
            return cached.map(StashDBScene.init)
        }
        if let snaps: [StashDBScene.Snapshot] = StashDBCache.shared.read(
            key, ttl: StashDBCache.TTL.trending
        ) {
            StashDBCache.shared.memoWrite(key, value: snaps)
            return snaps.map(StashDBScene.init)
        }
        let fresh = await fetchNewScenes(
            performerStashIds: performerStashIds,
            sinceDate: sinceDate,
            apiKey: stashDBKey
        )
        let snaps = fresh.map(\.snapshot)
        if !fresh.isEmpty {
            StashDBCache.shared.write(key, value: snaps)
            StashDBCache.shared.memoWrite(key, value: snaps)
        }
        return fresh
    }

    func cachedTrendingPerformers(
        apiKey stashDBKey: String,
        perPage: Int = 30,
        genders: [String] = ["FEMALE"]
    ) async -> [StashDBTrendingPerformer] {
        // Sort the gender list before joining so the cache key is
        // permutation-invariant — ["FEMALE","MALE"] and
        // ["MALE","FEMALE"] share a single cache entry.
        let key =
            "trendingPerformers:\(genders.sorted().joined(separator: "+")):\(perPage)"
        if let cached: [StashDBTrendingPerformer.Snapshot] =
            StashDBCache.shared.memoRead(key)
        {
            return cached.map(StashDBTrendingPerformer.init)
        }
        if let snaps: [StashDBTrendingPerformer.Snapshot] =
            StashDBCache.shared.read(
                key, ttl: StashDBCache.TTL.trending
            )
        {
            StashDBCache.shared.memoWrite(key, value: snaps)
            return snaps.map(StashDBTrendingPerformer.init)
        }
        let fresh = await fetchTrendingPerformers(
            apiKey: stashDBKey, perPage: perPage, genders: genders
        )
        let snaps = fresh.map(\.snapshot)
        if !fresh.isEmpty {
            StashDBCache.shared.write(key, value: snaps)
            StashDBCache.shared.memoWrite(key, value: snaps)
        }
        return fresh
    }

    func cachedPerformerDetail(
        stashId: String, apiKey stashDBKey: String
    ) async -> StashDBPerformerDetail? {
        let key = "performerDetail:\(stashId)"
        if let snap: StashDBPerformerDetail.Snapshot =
            StashDBCache.shared.memoRead(key)
        {
            return StashDBPerformerDetail(snapshot: snap)
        }
        if let snap: StashDBPerformerDetail.Snapshot =
            StashDBCache.shared.read(
                key, ttl: StashDBCache.TTL.performerDetail
            )
        {
            StashDBCache.shared.memoWrite(key, value: snap)
            return StashDBPerformerDetail(snapshot: snap)
        }
        let fresh = await fetchPerformerDetail(
            stashId: stashId, apiKey: stashDBKey
        )
        if let fresh {
            StashDBCache.shared.write(key, value: fresh.snapshot)
            StashDBCache.shared.memoWrite(key, value: fresh.snapshot)
        }
        return fresh
    }

    func cachedScenesForStashDBPerformer(
        stashId: String, apiKey stashDBKey: String
    ) async -> [StashDBScene] {
        let key = "performerScenes:\(stashId)"
        if let cached: [StashDBScene.Snapshot] =
            StashDBCache.shared.memoRead(key)
        {
            return cached.map(StashDBScene.init)
        }
        if let snaps: [StashDBScene.Snapshot] = StashDBCache.shared.read(
            key, ttl: StashDBCache.TTL.performerDetail
        ) {
            StashDBCache.shared.memoWrite(key, value: snaps)
            return snaps.map(StashDBScene.init)
        }
        let fresh = await fetchScenesForStashDBPerformer(
            stashId: stashId, apiKey: stashDBKey
        )
        let snaps = fresh.map(\.snapshot)
        StashDBCache.shared.write(key, value: snaps)
        StashDBCache.shared.memoWrite(key, value: snaps)
        return fresh
    }
}
