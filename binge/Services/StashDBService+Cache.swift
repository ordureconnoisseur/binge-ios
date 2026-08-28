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
        guard let fresh = await fetchLinkedPerformers() else {
            // The fetch failed. Serve whatever is on disk, even if it is
            // past its TTL - a stale list of the user's own performers
            // is far better than an empty one - and write nothing, so
            // the next caller retries.
            let stale: [LinkedPerformer] =
                StashDBCache.shared.read(key, ttl: .greatestFiniteMagnitude)
                ?? []
            return stale
        }
        StashDBCache.shared.write(key, value: fresh)
        StashDBCache.shared.memoWrite(key, value: fresh)
        return fresh
    }

    /// nil when the answer is unknown. An empty set means the user owns
    /// none of these, which is a different and much more consequential
    /// claim - it is what decides whether a scene is offered with an
    /// Add button.
    func cachedOwnedStashIds() async -> Set<String>? {
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
        // Share one sweep across callers. The memo is only written after
        // the await returns, so without this two callers racing on a
        // cold cache each run a whole-library query for the same answer
        // — Home's discovery pass and a profile opened straight after it
        // will do exactly that. The task is static because every call
        // site builds its own StashDBService instance, so an
        // instance-level guard would not see the other one.
        if let inFlight = Self.ownedIdsInFlight {
            // A failure falls back to whatever is on disk, stale or not.
            // With nothing on disk it reports failure, because an empty
            // set here means "you own none of these" and that is the one
            // answer that must never be invented.
            if let shared = await inFlight.value { return shared }
            guard
                let stale: [String] = StashDBCache.shared.read(
                    key, ttl: .greatestFiniteMagnitude
                )
            else { return nil }
            return Set(stale)
        }
        let task = Task { await self.fetchOwnedStashIds() }
        Self.ownedIdsInFlight = task
        let result = await task.value
        Self.ownedIdsInFlight = nil
        guard let fresh = result else {
            // Stale beats empty, and a failure is never written - but a
            // COLD cache has no stale entry, and returning [] there was
            // the same fail-open this optional was introduced to close:
            // callers read it as "you own nothing", so every scene
            // already in the library came back offering Add.
            guard
                let stale: [String] = StashDBCache.shared.read(
                    key, ttl: .greatestFiniteMagnitude
                )
            else { return nil }
            return Set(stale)
        }
        let asArray = Array(fresh)
        StashDBCache.shared.write(key, value: asArray)
        StashDBCache.shared.memoWrite(key, value: asArray)
        return fresh
    }

    /// In-flight owned-ids sweep, shared across service instances.
    private static var ownedIdsInFlight: Task<Set<String>?, Never>?

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
        // Only written when something came back. An empty result from a
        // timeout used to be cached for 24 hours, so a profile opened on
        // a weak connection reported the performer as having no scenes -
        // and the sheet does not re-fetch once loaded, so that was the
        // answer until the next day or a pull-to-refresh.
        let fresh = await fetchScenesForStashDBPerformer(
            stashId: stashId, apiKey: stashDBKey
        )
        let snaps = fresh.map(\.snapshot)
        StashDBCache.shared.write(key, value: snaps)
        StashDBCache.shared.memoWrite(key, value: snaps)
        return fresh
    }
}
