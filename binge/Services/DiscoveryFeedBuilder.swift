import Foundation

// Builds DiscoveryItems from StashDB raw scenes + the user's
// linked-performers / owned-stash-ids state. Direct port of
// fetchDiscoveryFeedItems in src/home/discoveryFeed.ts.
//
// Two seeds:
//   1. Co-star — StashDB scenes featuring any library performer
//      (high signal, uncapped). Fetched only when the user has
//      ≥1 linked performer.
//   2. Trending — StashDB's homepage trending list, capped at the
//      first MAX_TRENDING items. Works for everyone, including
//      brand-new users with zero linked performers.
//
// Merged into one pool keyed by scene id (co-star takes
// precedence when the same scene surfaces in both). Each scene
// picks a headline female performer (library-first, else most-
// popular unfollowed) and contributes one card.
enum DiscoveryFeedBuilder {
    /// Per-performer headline cap. A prolific performer shouldn't
    /// monopolize the feed.
    private static let maxScenesPerPrimary = 2
    /// Hard cap on trending-source items (co-star is uncapped —
    /// naturally bounded by library size).
    private static let maxTrendingItems = 12

    @MainActor
    static func build(
        costarScenes: [StashDBScene],
        trendingScenes: [StashDBScene],
        linkedPerformers: [LinkedPerformer],
        ownedSceneStashIds: Set<String>,
        allowedGenders: Set<String> = AllowedGendersStore.currentStrings()
    ) -> [DiscoveryItem] {
        // Index library performers by their stash_id for O(1)
        // gender / library-membership checks.
        var stashIdToLocal: [
            String: (localId: String, name: String, favorite: Bool)
        ] = [:]
        for p in linkedPerformers {
            stashIdToLocal[p.stashId] = (p.localId, p.name, p.favorite)
        }

        // Merge co-star + trending, deduped by scene id. Trending
        // takes precedence — being in StashDB's global top-N is a
        // stronger signal than "features a library performer"
        // (which the user's library already covers as baseline).
        // Without this flip, almost every trending scene also
        // matches the costar fetch and the TRENDING pill never
        // surfaces.
        var pool: [String: (scene: StashDBScene, source: DiscoveryItem.Source)] = [:]
        for s in trendingScenes.prefix(maxTrendingItems)
        where !ownedSceneStashIds.contains(s.id) {
            if pool[s.id] == nil {
                pool[s.id] = (s, .trending)
            }
        }
        for s in costarScenes where !ownedSceneStashIds.contains(s.id) {
            if pool[s.id] == nil {
                pool[s.id] = (s, .costar)
            }
        }

        var items: [DiscoveryItem] = []
        var headlineCounts: [String: Int] = [:]

        for (_, entry) in pool {
            let scene = entry.scene
            let female = scene.performers.filter { perf in
                guard let g = perf.gender else { return false }
                return allowedGenders.contains(g)
            }
            guard !female.isEmpty else { continue }

            let libraryPerf = female.first(where: {
                stashIdToLocal[$0.id] != nil
            })
            let unfollowedFemale = female
                .filter { stashIdToLocal[$0.id] == nil }
                .sorted {
                    if $0.sceneCount != $1.sceneCount {
                        return $0.sceneCount > $1.sceneCount
                    }
                    return $0.name < $1.name
                }

            // Two-gate skip — kept in sync with web's
            // src/home/discoveryFeed.ts. Either gate means "no
            // actionable signal" → don't render the card.
            //   1. No candidate-gender performer on the scene at all.
            //   2. (costar only) Library headline picked, but no
            //      unfollowed co-stars to drive a Follow. Trending
            //      cards bypass this gate — even an all-library
            //      trending scene carries information value (it's
            //      what StashDB is surfacing right now).
            if libraryPerf == nil && unfollowedFemale.isEmpty { continue }
            if entry.source == .costar
                && libraryPerf != nil
                && unfollowedFemale.isEmpty
            {
                continue
            }

            let poster = libraryPerf ?? unfollowedFemale[0]
            let posterCount = headlineCounts[poster.id] ?? 0
            if posterCount >= maxScenesPerPrimary { continue }
            headlineCounts[poster.id] = posterCount + 1

            let posterLocal = stashIdToLocal[poster.id]
            let coPerformers: [DiscoveryItem.Performer] = scene.performers
                .filter { $0.id != poster.id }
                .filter { perf in
                    guard let g = perf.gender else { return false }
                    return allowedGenders.contains(g)
                }
                .map {
                    let local = stashIdToLocal[$0.id]
                    return DiscoveryItem.Performer(
                        stashId: $0.id,
                        name: $0.name,
                        image: $0.image,
                        gender: $0.gender,
                        birthDate: $0.birthDate,
                        localId: local?.localId,
                        favorite: local?.favorite ?? false
                    )
                }

            let effectiveAt: String =
                scene.releaseDate
                ?? ISO8601DateFormatter().string(from: Date()).prefix(10)
                    .description

            items.append(
                DiscoveryItem(
                    id: "discovery:\(scene.id)",
                    sceneStashId: scene.id,
                    title: scene.title,
                    coverUrl: scene.coverUrl,
                    releaseDate: scene.releaseDate,
                    effectiveAt: effectiveAt,
                    stashboxUrl: "https://stashdb.org/scenes/\(scene.id)",
                    primaryPerformer: DiscoveryItem.Performer(
                        stashId: poster.id,
                        name: poster.name,
                        image: poster.image,
                        gender: poster.gender,
                        birthDate: poster.birthDate,
                        localId: posterLocal?.localId,
                        favorite: posterLocal?.favorite ?? false
                    ),
                    primaryInLibrary: posterLocal != nil,
                    coPerformers: coPerformers,
                    source: entry.source
                )
            )
        }

        // Newest effectiveAt first.
        return items.sorted { $0.effectiveAt > $1.effectiveAt }
    }
}
