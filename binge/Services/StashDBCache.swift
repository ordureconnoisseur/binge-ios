import Foundation

// JSON-on-disk cache for StashDB lookups. Mirrors the web's
// localStorage `binge.stashdb.newScenes.v4` pattern but generalized
// to every StashDB-side surface, since iOS re-fires `.task` on every
// tab return — fetch-on-mount without a cache pays ~1–3s of StashDB
// latency every time the user touches Home or Explore.
//
// Storage: JSON files under Caches/binge-stashdb-cache/. Previously
// UserDefaults, but the `newScenes` payload (up to ~5k scenes) overflowed
// the 4MB CFPreferences limit and got rejected ("Attempting to store >=
// 4194304 bytes ... is invalid"); the filesystem has no such cap. init
// purges any old UserDefaults entries so a bloated domain is reclaimed.
//
// TTL is per-entry; callers pass it in. Defaults:
//   - trending lists      : 12h   (matches web)
//   - performer detail    : 24h   (bios change slowly)
//   - linked / owned IDs  : 1h    (user follows / adds scenes)
//   - stashBoxConfig      : 7d    (only changes when user edits Stash settings)
//
// Invalidation:
//   - `invalidateAll()` — full clear, called on pull-to-refresh.
//   - `invalidate(prefix:)` — wildcard clear (e.g. drop all
//     linked/owned after a Follow so the next fetch sees the
//     new performer).
//
// Thread-safety: UserDefaults is already thread-safe; this
// wrapper is a thin shim, so plain class + Sendable closures
// work fine. We expose async-flavored read/write helpers so
// the rest of the codebase doesn't have to think about blocking.
final class StashDBCache: @unchecked Sendable {
    static let shared = StashDBCache()

    /// On-disk cache directory under Caches.
    private let dir: URL = {
        let base = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        )[0]
        let d = base.appendingPathComponent(
            "binge-stashdb-cache", isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: d, withIntermediateDirectories: true
        )
        return d
    }()
    /// Bumped to v2 when the "don't cache empty arrays" rule landed.
    private let keyPrefix = "binge.stashdb.cache.v2."

    private init() {
        // One-time migration: purge the old UserDefaults-backed cache so
        // a previously-bloated (>4MB) preferences domain is reclaimed.
        let ud = UserDefaults.standard
        for k in ud.dictionaryRepresentation().keys
        where k.hasPrefix("binge.stashdb.cache.") {
            ud.removeObject(forKey: k)
        }
    }

    /// Map a cache key to a filesystem-safe filename — deterministic and
    /// prefix-preserving, so invalidate(prefix:) still matches by name.
    private func filename(for key: String) -> String {
        String((keyPrefix + key).map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
                ? $0 : "_"
        })
    }
    private func fileURL(for key: String) -> URL {
        dir.appendingPathComponent(filename(for: key))
    }

    /// Default TTLs as cleanly-named statics so call-sites read
    /// well — `ttl: .trending` beats `ttl: 43200`.
    enum TTL {
        static let trending: TimeInterval = 12 * 60 * 60
        static let performerDetail: TimeInterval = 24 * 60 * 60
        static let ownership: TimeInterval = 60 * 60
        static let stashBox: TimeInterval = 7 * 24 * 60 * 60
    }

    /// Read an entry. Returns nil on any miss path:
    ///   - key not present
    ///   - decode failure (schema drift across app versions)
    ///   - past TTL
    func read<T: Codable>(
        _ key: String, ttl: TimeInterval, as type: T.Type = T.self
    ) -> T? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard
            let entry = try? JSONDecoder().decode(
                CacheEntry<T>.self, from: data
            )
        else {
            // Stale schema — clear so subsequent writes start clean.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if Date().timeIntervalSince1970 - entry.fetchedAt > ttl {
            return nil
        }
        return entry.value
    }

    func write<T: Codable>(_ key: String, value: T) {
        let entry = CacheEntry(
            fetchedAt: Date().timeIntervalSince1970,
            value: value
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    /// Drop one entry. No-op if not present.
    func invalidate(_ key: String) {
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    /// Drop every entry whose key starts with the given suffix
    /// (the keyPrefix is added automatically). Used to nuke a
    /// family of entries — e.g. all `linked.*` after a Follow.
    func invalidate(prefix: String) {
        let namePrefix = filename(for: prefix)
        let fm = FileManager.default
        let files =
            (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            )) ?? []
        for f in files where f.lastPathComponent.hasPrefix(namePrefix) {
            try? fm.removeItem(at: f)
        }
    }

    /// Full clear of every cached StashDB lookup. Wired to
    /// pull-to-refresh on Home + Explore.
    func invalidateAll() {
        let fm = FileManager.default
        let files =
            (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            )) ?? []
        for f in files { try? fm.removeItem(at: f) }
    }

    /// In-memory hot path. Some workflows hit the cache multiple
    /// times in the same tab session (e.g. discovery bar + home
    /// both want linked performers); the disk round-trip + JSON
    /// decode adds up. This map shadows the disk; cleared on
    /// invalidate.
    private var memo: [String: Any] = [:]
    private let memoLock = NSLock()

    func memoRead<T>(_ key: String) -> T? {
        memoLock.lock()
        defer { memoLock.unlock() }
        return memo[key] as? T
    }
    func memoWrite<T>(_ key: String, value: T) {
        memoLock.lock()
        defer { memoLock.unlock() }
        memo[key] = value
    }
    func memoClear() {
        memoLock.lock()
        defer { memoLock.unlock() }
        memo.removeAll()
    }

    private struct CacheEntry<T: Codable>: Codable {
        let fetchedAt: TimeInterval
        let value: T
    }
}
