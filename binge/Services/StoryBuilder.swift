import Foundation

// Pure transform: merged library scenes + optional per-performer
// StashDB tail → grouped `Story` list. Mirrors the library-only
// path of the web plugin's useStories() plus its mergeStashDBScenes
// step.
//
// Each library scene contributes one row PER PERFORMER (a scene
// with 3 performers shows up in 3 performers' strips), but within
// a performer's strip the scene appears once. StashDB scenes are
// keyed by Stash localId (passed in via the `stashDBByLocalId`
// map) — the caller resolves StashDB performer.stashId → localId
// before handing them here so StoryBuilder stays pure.
//
// Within each performer's strip: library scenes head the list
// (playable items at the front of the progress strip), then
// StashDB scenes (discovery tail). Both sub-arrays are sorted by
// effectiveAt DESC.
enum StoryBuilder {
    private static let maxStories = 150

    /// `redditByLocalId` carries digests fetched from binge-server,
    /// keyed by Stash localId (the daemon's performer_stash_id
    /// field). Each entry brings a fallback `BingeScene.Performer`
    /// so reddit-only performers (no library, no StashDB) still
    /// surface in the row.
    struct RedditEntry {
        let posts: [RedditStoryPost]
        let fallbackPerformer: BingeScene.Performer
    }

    static func build(
        from libraryScenes: [BingeScene],
        stashDBByLocalId: [String: [StashDBStoryScene]] = [:],
        redditByLocalId: [String: RedditEntry] = [:]
    ) -> [Story] {
        struct Bucket {
            var performer: BingeScene.Performer
            var library: [BingeScene] = []
            var librarySeen: Set<String> = []
            var stashDB: [StashDBStoryScene] = []
            var reddit: [RedditStoryPost] = []
            /// Dedupe by mediaUrl so crossposts of the same image
            /// or video don't render twice in a row.
            var redditMediaSeen: Set<String> = []
        }
        var buckets: [String: Bucket] = [:]

        // Pass 1 — library scenes.
        for scene in libraryScenes {
            for p in scene.performers {
                var b = buckets[p.id] ?? Bucket(performer: p)
                if b.librarySeen.contains(scene.id) { continue }
                b.librarySeen.insert(scene.id)
                b.library.append(scene)
                buckets[p.id] = b
            }
        }

        // Pass 2 — StashDB tail. Creates no new buckets — a
        // StashDB-only performer falls through and surfaces via
        // Reddit (or not at all). The caller resolves stash_id →
        // local_id; entries without a matching library performer
        // are dropped here.
        for (localId, sceneList) in stashDBByLocalId {
            guard var b = buckets[localId] else { continue }
            b.stashDB.append(contentsOf: sceneList)
            buckets[localId] = b
        }

        // Pass 3 — Reddit tail. UNLIKE StashDB, reddit DOES create
        // a new bucket when the performer has no library scenes —
        // the daemon's fallback performer record gives us a name +
        // image_path to render the bubble. Matches web's behaviour
        // in mergeRedditPosts.
        for (localId, entry) in redditByLocalId {
            var b = buckets[localId]
                ?? Bucket(performer: entry.fallbackPerformer)
            for post in entry.posts {
                if let media = post.mediaUrl {
                    if b.redditMediaSeen.contains(media) { continue }
                    b.redditMediaSeen.insert(media)
                }
                b.reddit.append(post)
            }
            buckets[localId] = b
        }

        // Pass 4 — sort + assemble. Order within a strip:
        // library → stashDB → reddit. Library leads because that's
        // the user's owned content; reddit trails because it's the
        // social tail and the kinds (image/text/link) feel less
        // "watch-this" than playable scenes.
        let stories: [Story] = buckets.values.compactMap { b in
            let sortedLibrary = b.library.sorted {
                Story.effectiveAt(for: $0) > Story.effectiveAt(for: $1)
            }
            let sortedStashDB = b.stashDB.sorted {
                $0.effectiveAt > $1.effectiveAt
            }
            let sortedReddit = b.reddit.sorted {
                $0.createdUtc > $1.createdUtc
            }
            let combined: [StoryScene] =
                sortedLibrary.map(StoryScene.library)
                + sortedStashDB.map(StoryScene.stashDB)
                + sortedReddit.map(StoryScene.reddit)
            guard !combined.isEmpty else { return nil }
            // Row-order key across performers: the most-recent
            // effectiveAt across all three sources. Each sub-array
            // is sorted DESC so heads are the candidates.
            let libraryHead = sortedLibrary.first.map(Story.effectiveAt(for:))
                ?? ""
            let stashDBHead = sortedStashDB.first?.effectiveAt ?? ""
            let redditHead = sortedReddit.first?.effectiveAt ?? ""
            let latest = max(libraryHead, max(stashDBHead, redditHead))
            return Story(
                performer: b.performer,
                scenes: combined,
                latestEffectiveAt: latest
            )
        }
        return stories
            .sorted { $0.latestEffectiveAt > $1.latestEffectiveAt }
            .prefix(maxStories)
            .map { $0 }
    }
}
