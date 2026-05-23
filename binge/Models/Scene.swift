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
    // Default: pass paths.stream through unchanged. That's the URL
    // Stash assembles + signs with the apikey query string; works
    // for every H.264 scene tested.
    //
    // HEVC scenes: AVPlayer's hardware decoder rejects the raw
    // file. Surgically append `.mp4` to the stream path to force
    // Stash's MP4 transcode endpoint (`/scene/<id>/stream.mp4`).
    // We touch ONLY the path component, leaving the query string
    // (including `?apikey=...`) untouched — so auth keeps working
    // exactly the way the default URL does. Avoids going through
    // sceneStreams[] altogether (those entries had auth quirks we
    // couldn't resolve).
    //
    // Diagnostic logging stays — when something fails, the Xcode
    // console shows the picked URL + codec + advertised
    // sceneStreams labels so we can iterate.
    func streamURL(base: String) -> URL? {
        guard let stream = paths.stream else { return nil }
        let chosen = isHEVC ? forceMP4Extension(stream) : stream
        return logged(absoluteURL(chosen, base: base))
    }

    /// True when the source file's codec is HEVC / H.265. Matches
    /// "hevc", "h265", "h.265" — different Stash + ffprobe
    /// versions report it slightly differently.
    var isHEVC: Bool {
        guard let codec = files.first?.videoCodec?.lowercased() else {
            return false
        }
        return codec.contains("hevc")
            || codec.contains("h265")
            || codec.contains("h.265")
    }

    /// Take a URL like `https://host/scene/123/stream?apikey=...`
    /// and rewrite the path to `/scene/123/stream.mp4`, keeping
    /// the query string intact. Stash treats `/stream.mp4` as an
    /// explicit MP4 transcode request — which forces H.264 on the
    /// wire and is universally decodable by AVPlayer.
    ///
    /// Idempotent: if the path already ends with `.mp4`, returns
    /// the input unchanged.
    private func forceMP4Extension(_ urlString: String) -> String {
        let qIdx = urlString.firstIndex(of: "?")
        let path: String
        let query: String
        if let qIdx {
            path = String(urlString[..<qIdx])
            query = String(urlString[qIdx...])
        } else {
            path = urlString
            query = ""
        }
        if path.hasSuffix(".mp4") { return urlString }
        return path + ".mp4" + query
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
