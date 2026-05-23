import Foundation

// GraphQL query strings ported from the web plugin's src/api/queries.ts.
// One string per query, named identically so the cross-reference is
// obvious. Companion `Codable` response types live in Models/.
enum Mutations {
    /// Increment the scene's O-counter. Mirrors the web plugin's
    /// `sceneIncrementO` mutation — used by the double-tap-to-like
    /// gesture in the reel.
    static let sceneIncrementO = """
        mutation SceneIncrementO($id: ID!) {
            sceneIncrementO(id: $id)
        }
        """
}

struct IncrementOResponse: Decodable {
    let sceneIncrementO: Int
}

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
    ///
    /// `files.video_codec` is fetched so the reel can detect HEVC
    /// content and force a MP4 (H.264) transcode — AVPlayer's HEVC
    /// support is patchy across encoder profiles and a fallback is
    /// needed.
    ///
    /// `sceneStreams` mirrors what Stash's web UI uses to pick a
    /// transcode endpoint: list of `{url, label, mime_type}` where
    /// labels are like "Direct stream", "MP4", "WEBM", "HLS". We
    /// pick by label substring (matching the web app's pickStream).
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
              files {
                duration
                width
                height
                video_codec
              }
              sceneStreams {
                url
                label
                mime_type
              }
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
