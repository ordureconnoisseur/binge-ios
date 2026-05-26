import Foundation

// Paginated sweep over findPerformers. Stash returns up to a
// configurable per_page; this helper walks pages until either the
// reported `count` is reached, an empty page comes back, or a
// safety ceiling kicks in.
//
// Used by FollowingViewModel — performers don't change often, so a
// single boot-time sweep is reasonable. For libraries past ~5k
// performers we'd want to switch to incremental loading.
enum PerformerSweep {
    private static let perPage = 250
    /// 20k performer ceiling — defensive limit against a server bug
    /// that reports a wrong `count`.
    private static let maxPages = 80

    static func all(client: StashClient) async throws -> [PerformerSummary] {
        var all: [PerformerSummary] = []
        var page = 1
        var totalCount = Int.max
        while page <= maxPages && all.count < totalCount {
            let resp: FindPerformersResponse = try await client.gql(
                Queries.findPerformersPage,
                variables: ["page": page, "perPage": perPage]
            )
            totalCount = resp.findPerformers.count
            let chunk = resp.findPerformers.performers
            all.append(contentsOf: chunk)
            if chunk.isEmpty { break }
            if chunk.count < perPage { break }
            page += 1
        }
        return all
    }
}
