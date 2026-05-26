import Foundation

// Weighted-context recommendation engine seeded by an Explore tile
// tap. Direct port of src/reel/chainAlgo.ts.
//
// Each played scene contributes its performers + tags to two
// weighted maps; subsequent picks score candidates by overlap with
// those maps and weighted-randomly pick from the top-N.
//
// Tunables (defaults below):
//   - chainRate         — fraction of picks that follow context vs
//                         pure-random injection. 0.8 = 4 in 5 chained.
//   - decayRate         — multiplier applied to every weight after a
//                         play. 0.85 ≈ "feel the last 4–5 scenes most".
//   - branchThreshold   — N plays with the same dominant attribute
//                         forces a random injection (escape valve so
//                         the chain doesn't get stuck on one niche).
@MainActor
final class ChainAlgo {
    // MARK: - Tunables

    // `nonisolated` so they can be used as default-arg expressions
    // in init — without it Swift 6 actor-isolation rules treat
    // accessing them outside the MainActor context as an error.
    nonisolated static let defaultChainRate: Double = 0.8
    nonisolated static let defaultDecayRate: Double = 0.85
    nonisolated static let defaultBranchThreshold: Int = 4

    // Candidate pool size pulled per attribute. 30 strikes a
    // balance — wide enough to give the scorer something to choose
    // from, narrow enough that the GraphQL response stays cheap.
    private static let poolPerAttribute: Int = 30
    // Top K context attributes (by weight) into each query.
    private static let topKAttributes: Int = 3
    // Top-N candidates considered for weighted-random selection.
    private static let topNForRandomPick: Int = 10
    // Performer matches feel stronger than tag matches (shared
    // performer ≈ same person; shared tag = vibe).
    private static let performerScoreMultiplier: Double = 1.5

    // MARK: - State

    private(set) var performers: [String: Double] = [:]
    private(set) var tags: [String: Double] = [:]
    private(set) var visited: Set<String> = []
    private var sameDominantStreak: Int = 0
    private var lastDominantKey: String?

    private let chainRate: Double
    private let decayRate: Double
    private let branchThreshold: Int

    private let baseURL: String
    private let apiKey: String

    // Session-stable random seed so random-injection pages don't
    // reshuffle across calls.
    private let randomSeed: String
    private var randomPage: Int = 1

    // MARK: - Init

    init(
        baseURL: String,
        apiKey: String,
        chainRate: Double = defaultChainRate,
        decayRate: Double = defaultDecayRate,
        branchThreshold: Int = defaultBranchThreshold,
        initialVisited: [String] = []
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.chainRate = chainRate
        self.decayRate = decayRate
        self.branchThreshold = branchThreshold
        self.visited = Set(initialVisited)
        self.randomSeed = "random_\(Int.random(in: 0..<1_000_000_000))"
    }

    // MARK: - Public API

    /// Called when a scene becomes the active slide. Adds the
    /// scene's performers + tags to the context (incrementing
    /// existing weights), decays all prior weights, and updates
    /// the dominant-attribute streak counter.
    func onPlay(scene: BingeScene) {
        visited.insert(scene.id)
        decay(&performers)
        decay(&tags)
        for p in scene.performers {
            performers[p.id, default: 0] += 1
        }
        for t in scene.tags {
            tags[t.id, default: 0] += 1
        }
        recomputeDominant()
    }

    /// Returns the next batch of scenes to append to the reel.
    /// Up to `size` scenes; may return fewer if the library is
    /// exhausted. Picks are interleaved chained vs random per the
    /// chainRate, with forced random injection when the dominant-
    /// attribute streak hits branchThreshold.
    func nextBatch(size: Int) async -> [BingeScene] {
        var out: [BingeScene] = []
        var chainedPool = await fetchChainedCandidates()
        // Pre-sort by score so weightedPick takes a top slice.
        chainedPool.sort { scoreCandidate($0) > scoreCandidate($1) }
        var localPicked: Set<String> = []
        var reserveRandom: [BingeScene] = []

        @MainActor
        func ensureRandomReserve() async {
            guard reserveRandom.isEmpty else { return }
            let fresh = await fetchRandomBatch(size: max(size, 10))
            for s in fresh where !localPicked.contains(s.id) {
                reserveRandom.append(s)
            }
        }

        for _ in 0..<size {
            // Force-random when the streak hits the branch threshold,
            // so the chain can't get stuck on one niche.
            let forceRandom = sameDominantStreak >= branchThreshold
            let hasContext = !performers.isEmpty || !tags.isEmpty
            let wantChain =
                !forceRandom && hasContext
                && Double.random(in: 0..<1) < chainRate

            if wantChain {
                let filtered = chainedPool.filter {
                    !localPicked.contains($0.id)
                }
                if let picked = weightedPick(from: filtered) {
                    out.append(picked)
                    localPicked.insert(picked.id)
                    continue
                }
                // Pool exhausted — fall through to random.
            }

            await ensureRandomReserve()
            if reserveRandom.isEmpty { break }
            let picked = reserveRandom.removeFirst()
            out.append(picked)
            localPicked.insert(picked.id)
            if forceRandom {
                sameDominantStreak = 0
            }
        }

        return out
    }

    // MARK: - Internal: scoring + decay

    private func decay(_ map: inout [String: Double]) {
        // Drop weights that have decayed to negligible to keep
        // the INCLUDES query lists tidy. 0.05 ≈ 6 plays-ago at
        // decay 0.85.
        for (k, w) in map {
            let next = w * decayRate
            if next < 0.05 {
                map.removeValue(forKey: k)
            } else {
                map[k] = next
            }
        }
    }

    private func topK(_ map: [String: Double], k: Int) -> [String] {
        Array(
            map.sorted { $0.value > $1.value }
                .prefix(k)
                .map { $0.key }
        )
    }

    private func scoreCandidate(_ scene: BingeScene) -> Double {
        var score: Double = 0
        for p in scene.performers {
            score +=
                (performers[p.id] ?? 0)
                * Self.performerScoreMultiplier
        }
        for t in scene.tags {
            score += tags[t.id] ?? 0
        }
        return score
    }

    /// Weighted-random pick from the top-N candidates by score.
    /// Candidates must be pre-sorted DESC by score.
    private func weightedPick(from sorted: [BingeScene]) -> BingeScene? {
        guard !sorted.isEmpty else { return nil }
        let top = Array(sorted.prefix(Self.topNForRandomPick))
        let total = top.reduce(0.0) { $0 + scoreCandidate($1) }
        if total <= 0 {
            // All zeros — degrade to uniform random across the
            // top slice.
            return top.randomElement()
        }
        var r = Double.random(in: 0..<1) * total
        for c in top {
            r -= scoreCandidate(c)
            if r <= 0 { return c }
        }
        return top.last
    }

    // MARK: - Internal: dominant-streak

    private func dominantOf(
        _ map: [String: Double],
        prefix: String
    ) -> (key: String, weight: Double)? {
        guard let best = map.max(by: { $0.value < $1.value }) else {
            return nil
        }
        return ("\(prefix):\(best.key)", best.value)
    }

    private func recomputeDominant() {
        let p = dominantOf(performers, prefix: "p")
        let t = dominantOf(tags, prefix: "t")
        let winner: (key: String, weight: Double)?
        if p == nil {
            winner = t
        } else if t == nil {
            winner = p
        } else if p!.weight >= t!.weight {
            winner = p
        } else {
            winner = t
        }
        let next = winner?.key
        if next == lastDominantKey, next != nil {
            sameDominantStreak += 1
        } else {
            lastDominantKey = next
            sameDominantStreak = (next == nil) ? 0 : 1
        }
    }

    // MARK: - Internal: fetching

    private func fetchRandomBatch(size: Int) async -> [BingeScene] {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindScenesResponse = try await client.gql(
                Queries.findScenesExplore,
                variables: [
                    "page": randomPage,
                    "perPage": size,
                    "sort": randomSeed,
                    "q": "",
                ]
            )
            randomPage += 1
            return resp.findScenes.scenes.filter {
                !visited.contains($0.id)
            }
        } catch {
            print("[binge] chain randomBatch failed: \(error)")
            return []
        }
    }

    private func fetchChainedCandidates() async -> [BingeScene] {
        let perfIds = topK(performers, k: Self.topKAttributes)
        let tagIds = topK(tags, k: Self.topKAttributes)
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)

        async let performerScenes: [BingeScene] = perfIds.isEmpty
            ? []
            : fetchPerformerCandidates(client: client, ids: perfIds)
        async let tagScenes: [BingeScene] = tagIds.isEmpty
            ? []
            : fetchTagCandidates(client: client, ids: tagIds)

        let (a, b) = await (performerScenes, tagScenes)
        var seen: Set<String> = []
        var out: [BingeScene] = []
        for s in a + b {
            if seen.contains(s.id) { continue }
            if visited.contains(s.id) { continue }
            seen.insert(s.id)
            out.append(s)
        }
        return out
    }

    private func fetchPerformerCandidates(
        client: StashClient,
        ids: [String]
    ) async -> [BingeScene] {
        do {
            let resp: FindScenesResponse = try await client.gql(
                Queries.findScenesByPerformersRandom,
                variables: [
                    "performerIds": ids,
                    "perPage": Self.poolPerAttribute,
                ]
            )
            return resp.findScenes.scenes
        } catch {
            print("[binge] chain performer candidates failed: \(error)")
            return []
        }
    }

    private func fetchTagCandidates(
        client: StashClient,
        ids: [String]
    ) async -> [BingeScene] {
        do {
            let resp: FindScenesResponse = try await client.gql(
                Queries.findScenesByTagsRandom,
                variables: [
                    "tagIds": ids,
                    "perPage": Self.poolPerAttribute,
                ]
            )
            return resp.findScenes.scenes
        } catch {
            print("[binge] chain tag candidates failed: \(error)")
            return []
        }
    }
}
