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
    // Default: pass paths.stream through unchanged. That URL works
    // for every H.264 scene tested. HEVC scenes get audio but
    // black video (AVPlayer's decoder rejects them); the .mp4
    // path-rewrite trial made HEVC scenes break entirely, so
    // we've rolled that back too. Need to see the sceneStreams[]
    // URLs to pick the right one — the log below now prints them
    // in full.
    func streamURL(base: String) -> URL? {
        guard let stream = paths.stream else { return nil }
        return logged(absoluteURL(stream, base: base))
    }

    /// True when the source file's codec is HEVC / H.265. Used to
    /// flag scenes we'd ideally route to a transcode endpoint —
    /// once we figure out which sceneStreams entry actually
    /// works.
    var isHEVC: Bool {
        guard let codec = files.first?.videoCodec?.lowercased() else {
            return false
        }
        return codec.contains("hevc")
            || codec.contains("h265")
            || codec.contains("h.265")
    }

    private func absoluteURL(_ pathOrURL: String, base: String) -> URL? {
        if pathOrURL.hasPrefix("http") { return URL(string: pathOrURL) }
        let trimmedBase = base.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return URL(string: "\(trimmedBase)\(pathOrURL)")
    }

    /// Console-log the picked URL plus full sceneStreams entries
    /// so we can see exactly what URL patterns Stash advertises
    /// for each transcode endpoint. Returns the URL untouched.
    ///
    /// Format: one line per sceneStreams entry, indented under
    /// the streamURL line — easier to grep / copy-paste than the
    /// previous summary form.
    private func logged(_ url: URL?) -> URL? {
        if let url {
            print(
                "[binge] streamURL[\(id)] "
                    + "codec=\(files.first?.videoCodec ?? "?") "
                    + "picked=\(url.absoluteString)"
            )
            for s in sceneStreams {
                print(
                    "[binge]   stream "
                        + "label=\(s.label ?? "?") "
                        + "mime=\(s.mimeType ?? "?") "
                        + "url=\(s.url)"
                )
            }
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
