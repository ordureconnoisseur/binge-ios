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

    // The URL the AVPlayer hits. By default, Stash's `paths.stream`
    // serves whatever transcode Stash decided was appropriate. But
    // AVPlayer has spotty support for HEVC profiles — we've seen
    // scenes play audio with a black video frame when the file is
    // HEVC-encoded with certain profiles or chroma sampling.
    //
    // Defence: when the file's video_codec is HEVC/H.265, look for
    // an explicit "MP4" entry in sceneStreams and use that instead.
    // Stash's MP4 transcode is H.264 — universally decodable by
    // AVPlayer. Falls back to paths.stream if no MP4 entry exists
    // (rare; means Stash has only Direct/HLS configured).
    func streamURL(base: String) -> URL? {
        if isHEVC, let mp4 = preferredMP4Stream() {
            return absoluteURL(mp4, base: base)
        }
        guard let stream = paths.stream else { return nil }
        return absoluteURL(stream, base: base)
    }

    /// True when the source file is HEVC/H.265. Matches "hevc",
    /// "h265", "h.265" forms (Stash version drift).
    var isHEVC: Bool {
        guard let codec = files.first?.videoCodec?.lowercased() else {
            return false
        }
        return codec.contains("hevc")
            || codec.contains("h265")
            || codec.contains("h.265")
    }

    /// Find the MP4 transcode endpoint from sceneStreams. Matches
    /// either the "MP4" label (excluding "Direct stream MP4" which
    /// is the raw file even when it's HEVC — defeats the purpose)
    /// or mime_type "video/mp4".
    private func preferredMP4Stream() -> String? {
        for s in sceneStreams {
            let label = (s.label ?? "").lowercased()
            let mime = (s.mimeType ?? "").lowercased()
            let isMP4 = label.contains("mp4") || mime == "video/mp4"
            let isDirect = label.contains("direct")
            if isMP4 && !isDirect {
                return s.url
            }
        }
        return nil
    }

    private func absoluteURL(_ pathOrURL: String, base: String) -> URL? {
        if pathOrURL.hasPrefix("http") { return URL(string: pathOrURL) }
        let trimmedBase = base.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return URL(string: "\(trimmedBase)\(pathOrURL)")
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
