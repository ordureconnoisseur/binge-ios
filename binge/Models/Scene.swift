import Foundation

// Codable mirror of the `BingeScene` shape the web plugin uses.
// Field selection matches Queries.findScenesRandom; if you add fields
// to the GraphQL query, add them here too.
struct BingeScene: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let details: String?
    let oCounter: Int?
    let paths: Paths
    let files: [FileInfo]
    let sceneStreams: [SceneStream]
    let performers: [Performer]
    let tags: [Tag]

    struct Paths: Decodable, Hashable {
        let stream: String?
        let screenshot: String?
        let preview: String?
    }

    struct FileInfo: Decodable, Hashable {
        let duration: Double?
        let width: Int?
        let height: Int?
        // Video codec name as Stash reports it. Lowercase forms
        // include "h264", "hevc", "vp9", "av1", "mpeg4", etc.
        // Used to detect HEVC content and force a H.264 transcode
        // (AVPlayer's HEVC support has profile-dependent gaps).
        let videoCodec: String?

        enum CodingKeys: String, CodingKey {
            case duration
            case width
            case height
            case videoCodec = "video_codec"
        }
    }

    // One of Stash's transcode endpoints. The web plugin matches
    // by label (case-insensitive substring); we mirror that.
    struct SceneStream: Decodable, Hashable {
        let url: String
        let label: String?
        let mimeType: String?

        enum CodingKeys: String, CodingKey {
            case url
            case label
            case mimeType = "mime_type"
        }
    }

    struct Performer: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
        let imagePath: String?
        let favorite: Bool

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case imagePath = "image_path"
            case favorite
        }
    }

    struct Tag: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case details
        case oCounter = "o_counter"
        case paths
        case files
        case sceneStreams
        case performers
        case tags
    }

    // The URL the AVPlayer hits.
    //
    // Reverted to the simple paths.stream default after a brief
    // experiment with "always force MP4 transcode" broke playback
    // for most scenes on the user's Stash install. The MP4
    // transcode endpoints listed in sceneStreams must require auth
    // handling we're not doing right (cookie vs ApiKey header, or
    // query-string apikey, etc.) — and we don't have visibility
    // into the failure mode from the iOS side.
    //
    // Diagnostic logging stays. When a scene fails, the Xcode
    // console shows exactly which URL was tried + the source
    // codec, which makes future fixes targeted instead of guesses.
    //
    // Future work: a Settings toggle (Auto / Direct / MP4 / HLS)
    // like the web app — opt-in transcode override for users who
    // know their Stash install supports a specific endpoint.
    func streamURL(base: String) -> URL? {
        guard let stream = paths.stream else { return nil }
        return logged(absoluteURL(stream, base: base))
    }

    private func absoluteURL(_ pathOrURL: String, base: String) -> URL? {
        if pathOrURL.hasPrefix("http") { return URL(string: pathOrURL) }
        let trimmedBase = base.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return URL(string: "\(trimmedBase)\(pathOrURL)")
    }

    /// Console-log the picked URL so debugging "this scene plays
    /// audio with a black frame" is just a matter of looking at
    /// the Xcode console. Returns the URL untouched.
    private func logged(_ url: URL?) -> URL? {
        if let url {
            let streamsSummary = sceneStreams
                .prefix(5)
                .map { "[\($0.label ?? "?")|\($0.mimeType ?? "?")]" }
                .joined(separator: " ")
            print(
                "[binge] streamURL[\(id)] "
                    + "codec=\(files.first?.videoCodec ?? "?") "
                    + "url=\(url.absoluteString) "
                    + "streams=\(streamsSummary)"
            )
        }
        return url
    }

    // Screenshot — used by SceneSlideView as a poster image behind
    // the AVPlayer during cold loads so the slide never shows
    // black before the first decoded frame.
    func screenshotURL(base: String) -> URL? {
        guard let screenshot = paths.screenshot else { return nil }
        if screenshot.hasPrefix("http") { return URL(string: screenshot) }
        return URL(string: "\(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(screenshot)")
    }
}

struct FindScenesResponse: Decodable {
    let findScenes: Payload
    struct Payload: Decodable {
        let count: Int
        let scenes: [BingeScene]
    }
}
