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
    // AVPlayer is fussier than the browser <video> element about
    // source variations — HEVC profiles, unusual chroma sampling,
    // certain MPEG-4 variants, container quirks. The web reel rides
    // on the browser's much wider compatibility envelope, so it can
    // default to `paths.stream` (Stash's "auto" choice, often the
    // raw file). iOS can't.
    //
    // Strategy on iOS: always prefer a transcoded endpoint over
    // the raw file. Stash's MP4 transcode is universally H.264 —
    // bulletproof on AVPlayer. HLS is the next-best — Stash
    // transcodes the segments to MP4 fragments which AVPlayer
    // handles natively. Only fall back to paths.stream when
    // neither transcode is configured (rare Stash install).
    //
    // Trade-off: pays the Stash-side transcode cost even for
    // files that would have played fine direct. Acceptable for
    // the reliability gain. Future work: a user-facing toggle
    // (Auto / Direct / MP4 / WebM / HLS) like the web app for
    // power users who want manual control.
    func streamURL(base: String) -> URL? {
        if let mp4 = preferredStream(matching: ["mp4"]) {
            return logged("MP4 transcode", absoluteURL(mp4, base: base))
        }
        if let hls = preferredStream(matching: ["hls", "mpegurl", "x-mpegurl"]) {
            return logged("HLS transcode", absoluteURL(hls, base: base))
        }
        guard let stream = paths.stream else { return nil }
        return logged("paths.stream fallback", absoluteURL(stream, base: base))
    }

    /// Pick a sceneStreams entry whose label or mime contains any
    /// of the given needles. Excludes "Direct stream" variants
    /// because those serve the raw file (with the label set to e.g.
    /// "Direct stream MP4" even if the file is HEVC).
    private func preferredStream(matching needles: [String]) -> String? {
        for s in sceneStreams {
            let label = (s.label ?? "").lowercased()
            let mime = (s.mimeType ?? "").lowercased()
            if label.contains("direct") { continue }
            for needle in needles {
                if label.contains(needle) || mime.contains(needle) {
                    return s.url
                }
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

    /// Console-log the picked URL so debugging "this scene plays
    /// audio with a black frame" is just a matter of looking at
    /// the Xcode console. Returns the URL untouched so it can be
    /// chained inline in the picker above.
    private func logged(_ kind: String, _ url: URL?) -> URL? {
        if let url {
            print(
                "[binge] streamURL[\(id)] kind=\(kind) "
                    + "codec=\(files.first?.videoCodec ?? "?") "
                    + "url=\(url.absoluteString)"
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
