import Foundation

// GraphQL query strings ported from the web plugin's src/api/queries.ts.
// One string per query, named identically so the cross-reference is
// obvious. Companion `Codable` response types live in Models/.
enum Queries {
    /// Connection check — used by SettingsView's "Connect" button.
    /// Returns Stash's running version; used only to confirm the
    /// URL + API key combination authenticates.
    static let version = """
        query Version { version { version } }
        """

    /// Random library scenes for the For-You reel. Mirrors
    /// findScenes() in src/api/queries.ts but only requests the
    /// fields v0.1 actually uses.
    static let findScenesRandom = """
        query FindScenes($page: Int!, $perPage: Int!, $sort: String!) {
          findScenes(filter: {
            page: $page,
            per_page: $perPage,
            sort: $sort,
            direction: DESC
          }) {
            count
            scenes {
              id
              title
              details
              o_counter
              paths { stream screenshot preview }
              files { duration }
              performers { id name image_path favorite }
              tags { id name }
            }
          }
        }
        """
}

// MARK: – Response types

struct VersionResponse: Decodable {
    let version: VersionPayload
    struct VersionPayload: Decodable { let version: String }
}
