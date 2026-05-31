import Foundation
import SwiftUI

// Drives the Explore tab. Holds the scene grid + the search query +
// the pagination cursor. Random sort with a session-stable seed
// (`random_<int>`) so swiping to page 2 doesn't reshuffle and dump
// duplicates on the user.
//
// Search is server-side via the `q` filter on findScenes; we
// debounce keystrokes by 300ms in the View layer so the user can
// type a word before a query fires.
@Observable
@MainActor
final class ExploreViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    var scenes: [BingeScene] = []
    var search: String = ""
    var loadState: LoadState = .idle
    var loadingMore: Bool = false
    var hasMore: Bool = false
    /// Active chip in the tag strip. `nil` = "For you" (no tag
    /// filter, random shuffle). Setting this from the View should
    /// be followed by `load()` to reset + reshuffle.
    var activeTag: InteractedTagsStore.TagScore?
    /// Top-N recency-scored tags from the local interaction ring.
    /// Populated on `loadChipStrip()`.
    var topTags: [InteractedTagsStore.TagScore] = []
    /// Server-derived fallback chips — only used when the local
    /// ring is too thin (< 3 entries) to feel personalized.
    var fallbackTags: [InteractedTagsStore.TagScore] = []

    /// Tags actually shown in the strip — picks `topTags` when
    /// they're substantial, otherwise the fallback. View reads
    /// this directly.
    var chipsToRender: [InteractedTagsStore.TagScore] {
        topTags.count >= 3 ? topTags : fallbackTags
    }

    private var page: Int = 1
    private let pageSize: Int = 30
    private var seenIds: Set<String> = []
    private static let maxChips = 12

    // Session-stable random seed. Pagination uses the same sort
    // across pages so the offset math doesn't pull from a fresh
    // shuffle each time. Changing search invalidates pagination
    // anyway — that's handled by resetting in `load`.
    private let sortSeed: String

    private let baseURL: String
    private let apiKey: String

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.sortSeed = "random_\(Int.random(in: 0..<1_000_000_000))"
    }

    /// Initial load (or reload after search changes). Resets the
    /// cursor + dedupe set. Idempotent — concurrent re-entry early
    /// returns.
    func load() async {
        if case .loading = loadState { return }
        loadState = .loading
        page = 1
        scenes = []
        seenIds = []
        hasMore = false
        await fetch(page: page, replace: true)
    }

    /// Refresh the chip-strip data. Reads the local interaction
    /// ring synchronously and (if it's too thin to feel
    /// personalized) fires the server-side recently-liked fallback
    /// in parallel.
    func loadChipStrip() async {
        topTags = InteractedTagsStore.topTags(limit: Self.maxChips)
        if topTags.count >= 3 {
            // Local signal is strong enough — skip the fallback
            // round-trip entirely.
            return
        }
        fallbackTags =
            await InteractedTagsStore.fetchRecentlyLikedTags(
                baseURL: baseURL,
                apiKey: apiKey,
                sceneSampleSize: 30,
                limit: Self.maxChips
            )
    }

    /// Append the next page when the user scrolls near the grid
    /// tail. Guards against double-fire from the multiple near-end
    /// tiles mounting at once.
    func loadMore() async {
        if loadingMore || !hasMore { return }
        if case .loading = loadState { return }
        loadingMore = true
        defer { loadingMore = false }
        let next = page + 1
        await fetch(page: next, replace: false)
    }

    private func fetch(page: Int, replace: Bool) async {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        var vars: [String: Any] = [
            "page": page,
            "perPage": pageSize,
            "sort": sortSeed,
            "q": search,
        ]
        // Optional INCLUDES filter for the active chip. Null when
        // no tag is selected so the server falls back to
        // unfiltered random.
        if let tag = activeTag {
            vars["sceneFilter"] = [
                "tags": [
                    "value": [tag.tagId],
                    "modifier": "INCLUDES",
                ]
            ]
        } else {
            vars["sceneFilter"] = NSNull()
        }
        do {
            let resp: FindScenesResponse = try await client.gql(
                Queries.findScenesExplore,
                variables: vars
            )
            let chunk = resp.findScenes.scenes.filteringHidden()
            let fresh = chunk.filter { !seenIds.contains($0.id) }
            for s in fresh { seenIds.insert(s.id) }
            if replace {
                scenes = fresh
            } else {
                scenes.append(contentsOf: fresh)
            }
            self.page = page
            hasMore =
                chunk.count == pageSize
                && scenes.count < resp.findScenes.count
            loadState = .loaded
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
            loadState = .error(msg)
            print("[binge] explore fetch failed: \(error)")
        }
    }
}
