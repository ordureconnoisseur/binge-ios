import Foundation

/// Local tracking of the user's recent tag interactions. Every
/// scene like, rate, or bookmark records the scene's tags in a
/// UserDefaults-backed ring buffer; Explore's chip strip reads the
/// top-N by recency-weighted frequency to surface one-tap filter
/// shortcuts shaped to the user's taste.
///
/// iOS port of web's `src/api/interactedTags.ts`. Same storage
/// shape (flat ring of `{tagId, tagName, ts}` JSON objects), same
/// 200-entry cap, same 60-day fresh window, same scoring formula
/// — so a user moving between web and iOS will see similar chips.
@MainActor
enum InteractedTagsStore {
    private static let storageKey = "binge.interactedTags"
    private static let ringLimit = 200
    private static let freshWindow: TimeInterval =
        60 * 24 * 60 * 60  // 60 days

    struct InteractionEvent: Codable {
        let tagId: String
        let tagName: String
        let ts: Double  // ms since epoch — matches web's Date.now()
    }

    struct TagScore: Identifiable, Hashable {
        let tagId: String
        let tagName: String
        let score: Double
        let lastSeenAt: Double
        var id: String { tagId }
    }

    /// Record an interaction with a list of tags. ASR/APR rating
    /// tags + binge collection tags are filtered before write so
    /// the recency ring stays free of plumbing noise.
    static func record(_ tags: [BingeScene.Tag]) {
        let filtered = tags.filter { !isSystemTagName($0.name) }
        if filtered.isEmpty { return }
        let now = Date().timeIntervalSince1970 * 1000
        var ring = readRing()
        for t in filtered {
            ring.append(
                InteractionEvent(
                    tagId: t.id, tagName: t.name, ts: now
                )
            )
        }
        if ring.count > ringLimit {
            ring.removeFirst(ring.count - ringLimit)
        }
        writeRing(ring)
    }

    /// Top N tags ranked by recency-weighted frequency. Linear
    /// decay across the fresh window — a tag interacted with
    /// yesterday counts roughly twice as much as one from 30 days
    /// ago.
    static func topTags(limit: Int) -> [TagScore] {
        let ring = readRing()
        if ring.isEmpty { return [] }
        let now = Date().timeIntervalSince1970 * 1000
        let cutoff = now - freshWindow * 1000
        var buckets: [String: TagScore] = [:]
        for e in ring where e.ts >= cutoff {
            let ageRatio = (now - e.ts) / (freshWindow * 1000)
            let weight = max(0, 1 - ageRatio)
            if let existing = buckets[e.tagId] {
                buckets[e.tagId] = TagScore(
                    tagId: existing.tagId,
                    tagName: existing.tagName,
                    score: existing.score + weight,
                    lastSeenAt: max(existing.lastSeenAt, e.ts)
                )
            } else {
                buckets[e.tagId] = TagScore(
                    tagId: e.tagId,
                    tagName: e.tagName,
                    score: weight,
                    lastSeenAt: e.ts
                )
            }
        }
        return buckets.values
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    /// Wipe the ring. Hook this into a future Settings "reset
    /// taste" action.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Server-side fallback when the local ring has fewer than 3
    /// entries. Aggregates tags from the user's `sceneSampleSize`
    /// most-recently-liked scenes and returns the `limit`
    /// highest-frequency ones — same shape and intent as web's
    /// `findRecentlyLikedTags`. Returns `[]` on any failure (the
    /// chip strip just renders without a fallback).
    static func fetchRecentlyLikedTags(
        baseURL: String,
        apiKey: String,
        sceneSampleSize: Int = 30,
        limit: Int = 10
    ) async -> [TagScore] {
        struct Response: Decodable {
            struct FindScenes: Decodable {
                let scenes: [Scene]
            }
            struct Scene: Decodable {
                let id: String
                let tags: [BingeScene.Tag]
            }
            let findScenes: FindScenes
        }
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: Response = try await client.gql(
                Queries.findRecentlyLikedScenes,
                variables: ["perPage": sceneSampleSize]
            )
            // Frequency aggregate; ties resolve by insertion order so
            // tags from the freshest likes win when counts match —
            // matches web's Map iteration order.
            var ordered: [String] = []
            var counts: [String: Int] = [:]
            var names: [String: String] = [:]
            let now = Date().timeIntervalSince1970 * 1000
            for scene in resp.findScenes.scenes {
                for tag in scene.tags {
                    if isSystemTagName(tag.name) { continue }
                    if counts[tag.id] == nil {
                        ordered.append(tag.id)
                        names[tag.id] = tag.name
                    }
                    counts[tag.id, default: 0] += 1
                }
            }
            return ordered
                .sorted { (a, b) in
                    let ca = counts[a] ?? 0
                    let cb = counts[b] ?? 0
                    if ca != cb { return ca > cb }
                    // Stable on tie via original insertion order
                    // (which `ordered` preserves) — this branch
                    // only matters when `sorted` is unstable,
                    // which Swift's stdlib isn't guaranteed to be.
                    return ordered.firstIndex(of: a)!
                        < ordered.firstIndex(of: b)!
                }
                .prefix(limit)
                .map {
                    TagScore(
                        tagId: $0,
                        tagName: names[$0] ?? "",
                        score: Double(counts[$0] ?? 0),
                        lastSeenAt: now
                    )
                }
        } catch {
            print("[binge] fetchRecentlyLikedTags failed: \(error)")
            return []
        }
    }

    // MARK: - Storage

    private static func readRing() -> [InteractionEvent] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
            let decoded = try? JSONDecoder().decode(
                [InteractionEvent].self, from: data
            )
        else { return [] }
        return decoded
    }

    private static func writeRing(_ ring: [InteractionEvent]) {
        guard let data = try? JSONEncoder().encode(ring) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Mirrors web's `isSystemTag` from src/api/tagFilters.ts:
    /// `… 📁` (binge collection), `… ★` (ASR criterion parent), or
    /// `<name> ★: <0-5>` (ASR score tag).
    private static func isSystemTagName(_ name: String) -> Bool {
        if name.isEmpty { return false }
        if name.hasSuffix(" 📁") { return true }
        if name.hasSuffix(" ★") { return true }
        if name.contains(" ★")
            && name.range(
                of: #"^(.+?)\s*:\s*([0-5])$"#,
                options: .regularExpression
            ) != nil
        {
            return true
        }
        return false
    }
}
