import Foundation
import SwiftUI

// Loads + manages state for a single performer profile.
//
// Two parallel queries on appear: full performer record + first
// page of their scenes. The hero/bio renders as soon as the
// performer arrives; the grid populates when scenes arrive.
//
// Favourite is owned here too — toggleFavourite optimistically
// flips a local boolean, then reconciles with the server-confirmed
// value (same pattern as ReelPerformerRow). Lives on the VM (not
// inside the hero subview) so the parent sheet can show the
// updated state immediately and the optimistic value survives a
// silent network failure.
@Observable
@MainActor
final class PerformerProfileViewModel {
    var performer: PerformerDetail?
    var scenes: [BingeScene] = []
    /// StashDB-only scenes (not owned in library) for this
    /// performer. Lazily fetched when the user flips the
    /// "Show StashDB content" toggle on the profile — empty
    /// otherwise. Interleaved by date with `scenes` in the UI.
    var stashDBScenes: [StashDBScene] = []
    var stashDBLoading: Bool = false
    /// True once a StashDB fetch has completed (even if it yielded
    /// zero unowned scenes), so toggling the section off/on doesn't
    /// re-hit the network when the result was legitimately empty.
    private var stashDBLoaded: Bool = false
    var loading: Bool = false
    var error: String?
    // Mirrors performer.favorite but flips immediately on tap so
    // the Favourite/Favourited pill responds without waiting for
    // the mutation round-trip.
    var favourite: Bool = false
    // Story for this performer when they have library scenes
    // within the lookback window. Drives the IG gradient ring on
    // the avatar + the story-viewer tap. nil when the performer
    // has no recent content.
    var story: Story?
    // Pagination state — infinite-scroll triggered by the
    // sheet's onScrollGeometryChange handler.
    var hasMore: Bool = false
    var loadingMore: Bool = false
    private var page: Int = 1
    private let pageSize: Int = 24

    // Same 30-day lookback as the Home stories row.
    private let storyLookbackDays = 30

    let performerId: String
    private let baseURL: String
    private let apiKey: String

    init(performerId: String, baseURL: String, apiKey: String) {
        self.performerId = performerId
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func load() async {
        if loading { return }
        loading = true
        defer { loading = false }
        // Reset pagination on (re)load so a refresh starts at page 1.
        page = 1
        scenes = []
        hasMore = false
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            async let detailResp: FindPerformerResponse = client.gql(
                Queries.findPerformer,
                variables: ["id": performerId]
            )
            async let scenesResp: FindScenesResponse = client.gql(
                Queries.findScenesForPerformer,
                variables: [
                    "performerId": performerId,
                    "page": page,
                    "perPage": pageSize,
                ]
            )
            let (detail, scenesData) = try await (detailResp, scenesResp)
            if let p = detail.findPerformer {
                performer = p
                favourite = p.favorite
            }
            self.scenes = scenesData.findScenes.scenes
            self.hasMore =
                scenesData.findScenes.scenes.count == pageSize
                && scenes.count < scenesData.findScenes.count
            self.story = buildStory(from: scenes)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription
                ?? "\(error)"
            print(
                "[binge] performer profile[\(performerId)] failed: \(error)"
            )
        }
    }

    /// Append the next page of scenes when the user scrolls near
    /// the bottom of the grid. Idempotent — re-entry while a load
    /// is in flight (or after exhaustion) is a no-op.
    func loadMore() async {
        if loadingMore || !hasMore || loading { return }
        loadingMore = true
        defer { loadingMore = false }
        let nextPage = page + 1
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let resp: FindScenesResponse = try await client.gql(
                Queries.findScenesForPerformer,
                variables: [
                    "performerId": performerId,
                    "page": nextPage,
                    "perPage": pageSize,
                ]
            )
            // Dedupe defensively — a scene added between page
            // fetches could land in both pages.
            let existing = Set(scenes.map(\.id))
            let fresh = resp.findScenes.scenes.filter {
                !existing.contains($0.id)
            }
            scenes.append(contentsOf: fresh)
            page = nextPage
            hasMore =
                resp.findScenes.scenes.count == pageSize
                && scenes.count < resp.findScenes.count
        } catch {
            print(
                "[binge] performer loadMore[\(performerId)] failed: \(error)"
            )
        }
    }

    // Construct a Story from scenes within the lookback window —
    // identical filter logic to HomeViewModel's stories row. Returns
    // nil when the performer has no recent content (no ring shown).
    //
    // We compare each scene's effectiveAt (date ?? createdAt) ISO
    // string against the threshold ISO. String comparison works
    // for these formats because they're lexicographically ordered
    // when both parsers' outputs are consistent — and both formats
    // (YYYY-MM-DD and YYYY-MM-DDTHH:MM:SSZ) start with the date.
    private func buildStory(from scenes: [BingeScene]) -> Story? {
        guard let perf = performer else { return nil }
        let cutoff = ISO8601DateFormatter().string(
            from: Calendar.current.date(
                byAdding: .day, value: -storyLookbackDays, to: Date()
            ) ?? Date()
        )
        let cutoffDate = String(cutoff.prefix(10))
        let recent = scenes.filter { scene in
            let eff = Story.effectiveAt(for: scene)
            // Either the date-only or full-ISO threshold beats the
            // effectiveAt — picking the date-only is safe because
            // YYYY-MM-DD precedes YYYY-MM-DDT... lexically.
            return !eff.isEmpty && eff >= cutoffDate
        }
        guard !recent.isEmpty else { return nil }
        let bingePerformer = BingeScene.Performer(
            id: perf.id,
            name: perf.name,
            imagePath: perf.imagePath,
            favorite: perf.favorite
        )
        // Story.scenes is now a [StoryScene] multi-source enum;
        // we wrap library BingeScenes in the .library case.
        return Story(
            performer: bingePerformer,
            scenes: recent.map(StoryScene.library),
            latestEffectiveAt: Story.effectiveAt(for: recent[0])
        )
    }

    /// One-shot fetch of StashDB-only scenes for this performer.
    /// Idempotent: subsequent calls are no-ops once we have data.
    /// Quietly degrades when the performer isn't linked, the
    /// stashbox isn't configured, or any call fails.
    func loadStashDBScenes() async {
        if stashDBLoaded || stashDBLoading { return }
        guard let stashId = performer?.stashDBId else { return }
        stashDBLoading = true
        defer { stashDBLoading = false }
        let svc = StashDBService(baseURL: baseURL, apiKey: apiKey)
        guard let box = await svc.fetchBoxConfig() else { return }
        let owned = await svc.fetchOwnedStashIds()
        let raw = await svc.fetchScenesForStashDBPerformer(
            stashId: stashId,
            apiKey: box.apiKey
        )
        // Skip scenes the user already owns — those are
        // already visible in the library grid via their local
        // entry; surfacing them again on stashdb tiles would
        // just be noise.
        stashDBScenes = raw.filter { !owned.contains($0.id) }
        stashDBLoaded = true
    }

    /// Drop the stashdb scenes when the user flips the toggle
    /// off — keeps the grid render trivial (just check
    /// `stashDBScenes.isEmpty`).
    func clearStashDBScenes() {
        stashDBScenes = []
        stashDBLoaded = false
    }

    func toggleFavourite() {
        let next = !favourite
        favourite = next
        Task {
            let client = StashClient(baseURL: baseURL, apiKey: apiKey)
            do {
                let resp: PerformerFavoriteResponse = try await client.gql(
                    Mutations.performerFavorite,
                    variables: [
                        "id": performerId,
                        "favorite": next,
                    ]
                )
                favourite = resp.performerUpdate.favorite
            } catch {
                print(
                    "[binge] performer favourite[\(performerId)] failed: \(error)"
                )
                favourite = !next  // roll back
            }
        }
    }
}
