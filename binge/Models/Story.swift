import Foundation

// One performer + the recent scenes that surface in their stories
// strip. Built by StoryBuilder from the merged output of library
// queries (findRecentScenes + findScenesByDate) + an optional
// StashDB tail (queryScenes against linked performers).
//
// `latestEffectiveAt` is the sort key — the most-recent
// `effectiveAt` across this performer's scenes, including
// stashdb content. Performers with only a fresh StashDB release
// still surface ahead of performers whose newest library scene
// is older.
struct Story: Identifiable, Hashable {
    var id: String { performer.id }
    let performer: BingeScene.Performer
    let scenes: [StoryScene]
    let latestEffectiveAt: String

    /// Effective date for ordering a library scene. Web parity:
    /// `scene.date ?? scene.created_at`, otherwise empty string.
    static func effectiveAt(for scene: BingeScene) -> String {
        scene.date ?? scene.createdAt ?? ""
    }
}

// Multi-source scene in a story strip. Library scenes play their
// preview clip via AVPlayer; StashDB scenes render their cover
// image with a 5s timer; Reddit posts render one of four sub-
// kinds (image / video / text / link).
enum StoryScene: Identifiable, Hashable {
    case library(BingeScene)
    case stashDB(StashDBStoryScene)
    case reddit(RedditStoryPost)

    var id: String {
        switch self {
        case .library(let s): return "lib:\(s.id)"
        case .stashDB(let s): return s.id
        case .reddit(let p): return p.id
        }
    }

    /// Used by StoryBuilder to sort within a performer's strip
    /// (freshest-first) AND by HomeViewModel to compute the
    /// row-order key across performers.
    var effectiveAt: String {
        switch self {
        case .library(let s):
            return Story.effectiveAt(for: s)
        case .stashDB(let s):
            return s.effectiveAt
        case .reddit(let p):
            return p.effectiveAt
        }
    }
}

// StashDB tail story — surfaces a release stashdb.org has for the
// performer that the user doesn't have locally yet. No preview
// clip (StashDB serves cover images only); the viewer renders the
// cover with a "View on StashDB →" CTA opening stashbox URL in
// the browser.
struct StashDBStoryScene: Identifiable, Hashable {
    /// Story-scoped id with `stashdb:` prefix so it never
    /// collides with library scene ids in dedupe sets / ForEach.
    let id: String
    /// Raw StashDB scene id (without the prefix). Used to build
    /// the stashbox URL.
    let stashId: String
    let title: String?
    let coverUrl: String?
    let releaseDate: String?
    /// release_date when present; today's date otherwise, so a
    /// dated-null trending hit still sorts to the top.
    let effectiveAt: String
    /// `https://stashdb.org/scenes/<id>` — viewer's CTA opens this.
    let stashboxUrl: String
}
