import Foundation

// Codable mirror of the `BingeScene` shape the web plugin uses.
// Field selection matches Queries.findScenesRandom; if you add fields
// to the GraphQL query, add them here too.
struct BingeScene: Decodable, Identifiable, Hashable {
    let id: String
    let title: String?
    let details: String?
    let oCounter: Int?
    // Play count + rating100 — optional so queries that don't select
    // them (the reel feed, etc.) still decode. The performer grid
    // selects them to drive the per-tile sort-stat badge.
    let playCount: Int?
    let rating100: Int?
    // Home-tab sort keys. Both are optional so the existing
    // findScenesRandom query — which doesn't select these fields —
    // still decodes cleanly. findRecentScenes / findScenesByDate
    // do select them.
    //
    // createdAt: ISO 8601 ("yyyy-MM-ddTHH:mm:ssZ") — when the scene
    //   was IMPORTED into the library.
    // date: bare "YYYY-MM-DD" — manual release date, may be nil for
    //   scenes the user hasn't tagged.
    let createdAt: String?
    let date: String?
    let paths: Paths
    let files: [FileInfo]
    let sceneStreams: [SceneStream]
    let performers: [Performer]
    let studio: Studio?
    let tags: [Tag]
    /// Stash-box matches for this scene. Optional because only the two
    /// Home queries select it; every other scene query decodes with it
    /// absent. Home needs it because a scene with nobody linked earns a
    /// place in the feed only if StashDB has identified it.
    ///
    /// `var`, not `let`: an optional `var` gets an implicit nil default
    /// in the memberwise init, so the hand-built scenes in DemoContent
    /// keep compiling without naming it. A `let` would not.
    var stashIds: [StashID]?

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
        let audioCodec: String?
        let frameRate: Double?
        // Stash returns size as Int64; Swift's `Int` is 64-bit on
        // iOS so it decodes cleanly. Optional in case Stash hasn't
        // indexed the file yet.
        let size: Int?
        let bitRate: Int?
        let path: String?

        enum CodingKeys: String, CodingKey {
            case duration
            case width
            case height
            case videoCodec = "video_codec"
            case audioCodec = "audio_codec"
            case frameRate = "frame_rate"
            case size
            case bitRate = "bit_rate"
            case path
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
        // Optional (defaults nil) so queries that don't select it still
        // decode and call sites that build a Performer manually need not
        // supply it. `var` (not `let`) so it stays in the memberwise init
        // — a `let` with a default is excluded. Drives the trans hide.
        var gender: String? = nil

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case imagePath = "image_path"
            case favorite
            case gender
        }
    }

    struct Tag: Decodable, Hashable, Identifiable {
        let id: String
        let name: String
    }

    struct Studio: Decodable, Hashable {
        let name: String
    }

    struct StashID: Decodable, Hashable {
        let endpoint: String
        let stashId: String

        enum CodingKeys: String, CodingKey {
            case endpoint
            case stashId = "stash_id"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case details
        case oCounter = "o_counter"
        case playCount = "play_count"
        case rating100
        case createdAt = "created_at"
        case date
        case paths
        case files
        case sceneStreams
        case performers
        case studio
        case tags
        case stashIds = "stash_ids"
    }

    // The URL the AVPlayer hits.
    //
    // Default: pass paths.stream through unchanged. Works for
    // every H.264 scene tested.
    //
    // HEVC: use Stash's HLS endpoint instead. HLS is AVPlayer's
    // native streaming format (`application/vnd.apple.mpegurl`);
    // Stash chunks the H.264-transcoded output into MP4 fragments
    // so playback can begin as soon as the first segment is ready
    // — no waiting for full-file transcode like the `.mp4`
    // endpoint required.
    //
    // Pick order honours the user's `binge.transcodeType`
    // preference from Settings (defaults to "auto"):
    //   - auto:   HEVC → HLS, else paths.stream (direct).
    //             Best for PC — no ffmpeg unless required.
    //   - direct: always paths.stream. May black-screen for
    //             HEVC on AVPlayer; user opt-in.
    //   - mp4:    MP4 transcode ladder (720p / 480p / orig).
    //             Faster first frame on iOS but each cold-miss
    //             scene triggers a Stash ffmpeg job.
    //   - hls:    HLS transcode ladder. Adaptive bitrate, good
    //             for shaky networks; also ffmpeg cost.
    //   - webm:   WebM transcode. AVPlayer can't play it on
    //             iOS — exposed for parity with the web client.
    func streamURL(base: String) -> URL? {
        // MKV is a CONTAINER AVFoundation can't demux at all — even an
        // H.264-in-MKV file fails direct playback. So it overrides both
        // the codec-based routing AND the user's stream-type preference
        // (incl. "direct"): always hand AVPlayer a transcoded stream.
        if isMKV {
            if let hls = firstHLSStreamURL() {
                return logged(absoluteURL(hls, base: base))
            }
            if let url = preferredStream(
                ladder: ["MP4 HD (720p)", "MP4 Standard (480p)", "MP4"],
                mime: "video/mp4"
            ) {
                return logged(absoluteURL(url, base: base))
            }
            // No transcode stream advertised — direct is the only option
            // left (will likely fail, but better than nil).
            return logged(directStreamURL(base: base))
        }

        let preference = UserDefaults.standard.string(
            forKey: "binge.transcodeType"
        ) ?? "auto"

        switch preference {
        case "direct":
            return logged(directStreamURL(base: base))
        case "mp4":
            if let url = preferredStream(
                ladder: [
                    "MP4 HD (720p)",
                    "MP4 Standard (480p)",
                    "MP4",
                ],
                mime: "video/mp4"
            ) {
                return logged(absoluteURL(url, base: base))
            }
            return logged(directStreamURL(base: base))
        case "hls":
            if let url = preferredStream(
                ladder: [
                    "HLS HD (720p)",
                    "HLS Standard (480p)",
                    "HLS",
                ],
                mime: "application/vnd.apple.mpegurl"
            ) {
                return logged(absoluteURL(url, base: base))
            }
            return logged(directStreamURL(base: base))
        case "webm":
            if let url = preferredStream(
                ladder: [
                    "WEBM HD (720p)",
                    "WEBM Standard (480p)",
                    "WEBM",
                ],
                mime: "video/webm"
            ) {
                return logged(absoluteURL(url, base: base))
            }
            return logged(directStreamURL(base: base))
        default:
            // auto: per-codec routing.
            //   - H264 → direct stream (no ffmpeg load).
            //   - HEVC → direct stream. The iPhone hardware-
            //     decodes HEVC Main / 8-bit 4:2:0 (what the
            //     library's transcode pipeline produces) natively.
            //     At the pipeline's ~1.4 Mbps a direct stream is
            //     FEWER bytes over the Tailscale link than Stash's
            //     H.264 transcode, with no ffmpeg load and no
            //     transcode-stall freeze, so playback starts fast.
            //     The minority of non-faststart HEVC files (moov
            //     atom at end-of-file) can't progressively stream
            //     and stall on direct play; the reel detects that
            //     and rebuilds against transcodeFallbackURL (HLS),
            //     recovering them to the old working path.
            //   - VP9 / AV1 / unknown → MP4 transcode ladder.
            //     HLS was unreliable for VP9 specifically (~10%
            //     of Instagram clips would black-screen even
            //     after rebuild, edge-case in Stash's VP9→HLS
            //     transcode that doesn't recover). Stash's
            //     VP9→H264 MP4 path goes through ffmpeg once,
            //     caches, and serves vanilla progressive MP4
            //     that AVPlayer handles unconditionally.
            if isHEVC {
                return logged(directStreamURL(base: base))
            }
            if needsTranscode {
                if let url = preferredStream(
                    ladder: [
                        "MP4 HD (720p)",
                        "MP4 Standard (480p)",
                        "MP4",
                    ],
                    mime: "video/mp4"
                ) {
                    return logged(absoluteURL(url, base: base))
                }
                if let hls = firstHLSStreamURL() {
                    return logged(absoluteURL(hls, base: base))
                }
            }
            return logged(directStreamURL(base: base))
        }
    }

    /// Transcoded URL to fall back to when a direct HEVC stream
    /// stalls - the non-faststart case (moov atom at end-of-file)
    /// that AVPlayer can't progressively stream over the network.
    /// Prefers Stash's HLS endpoint (the path HEVC used before
    /// direct became the default; battle-tested), then the MP4
    /// ladder. nil when no transcode stream is advertised, since
    /// there is then nothing to fall back to.
    func transcodeFallbackURL(base: String) -> URL? {
        if let hls = firstHLSStreamURL() {
            return absoluteURL(hls, base: base)
        }
        if let url = preferredStream(
            ladder: ["MP4 HD (720p)", "MP4 Standard (480p)", "MP4"],
            mime: "video/mp4"
        ) {
            return absoluteURL(url, base: base)
        }
        return nil
    }

    private func directStreamURL(base: String) -> URL? {
        guard let stream = paths.stream else { return nil }
        return absoluteURL(stream, base: base)
    }

    /// First sceneStreams entry matching one of the requested
    /// labels in order, filtered by mime type. nil if no match.
    private func preferredStream(
        ladder: [String],
        mime: String
    ) -> String? {
        for wanted in ladder {
            for s in sceneStreams
            where (s.label ?? "") == wanted
                && (s.mimeType ?? "").lowercased() == mime
            {
                return s.url
            }
        }
        return nil
    }

    /// True when the source container is Matroska (.mkv). AVFoundation
    /// can't open the MKV container regardless of the codecs inside, so
    /// these always need a transcoded stream — see `streamURL`.
    var isMKV: Bool {
        guard let path = files.first?.path?.lowercased() else {
            return false
        }
        return path.hasSuffix(".mkv")
    }

    /// True when the source file's codec is HEVC / H.265.
    var isHEVC: Bool {
        guard let codec = files.first?.videoCodec?.lowercased() else {
            return false
        }
        return codec.contains("hevc")
            || codec.contains("h265")
            || codec.contains("h.265")
    }

    /// True when AVPlayer can't reliably decode the source codec
    /// directly and needs a transcoded stream (we prefer HLS).
    /// Whitelist H264 (the broadly-supported codec that does
    /// stream cleanly) and treat everything else as needing
    /// transcode. Missing codec metadata also falls through to
    /// transcode — safer to transcode than black-screen.
    ///
    /// Hits in practice on the user's library:
    ///   - HEVC / H.265 (4K phone captures, recent encodes)
    ///   - VP9 (Instagram / TikTok sourced clips — was
    ///     black-screening because the previous isHEVC-only
    ///     gate let them through to direct stream)
    ///   - AV1 (rare today, future-proofing)
    var needsTranscode: Bool {
        guard let codec = files.first?.videoCodec?.lowercased()
        else { return true }
        let h264Aliases = ["h264", "h.264", "avc", "avc1"]
        return !h264Aliases.contains { codec.contains($0) }
    }

    /// First HLS endpoint Stash advertises in sceneStreams,
    /// matched by mime type (the official Apple HLS mime type is
    /// `application/vnd.apple.mpegurl`). Stash also exposes DASH
    /// (`application/dash+xml`) but AVPlayer's DASH support is
    /// patchier than its HLS support — HLS is the safer bet.
    /// Returns nil if no HLS endpoint is configured.
    ///
    /// History: briefly walked a 720p → 480p → original ladder
    /// here to ease the transcode load on big HEVC sources, but
    /// the user's library has at least some HEVC content where
    /// Stash's 720p HLS variant fails to play while ORIGINAL
    /// works. The first-entry behaviour is the proven path.
    private func firstHLSStreamURL() -> String? {
        for s in sceneStreams {
            if (s.mimeType ?? "").lowercased()
                == "application/vnd.apple.mpegurl"
            {
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

    /// One-line console log of the picked URL — useful enough as
    /// an "I see this codec, I picked this URL" check while the
    /// transcode routing was changing, retained as a low-noise
    /// signal. The full sceneStreams dump that lived here too was
    /// removed once the picker settled (per-scene ~20 lines of
    /// noise outweighed the diagnostic value).
    private func logged(_ url: URL?) -> URL? {
        if let url {
            print(
                "[binge] streamURL[\(id)] "
                    + "codec=\(files.first?.videoCodec ?? "?") "
                    + "picked=\(url.absoluteString)"
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

    // Preview clip — Stash's auto-generated short loop (~30s) for
    // each scene. Used by the Home tab's story viewer and feed
    // video sheets where we want fast playback start over full-
    // fidelity content.
    //
    // Caveat: Stash defaults to MP4 previews in recent versions,
    // but older installs may still produce WebM (VP9/Opus). AVPlayer
    // has no built-in WebM decoder — if previews don't play, the
    // user needs to set Stash's preview format to MP4 in Settings →
    // Tasks → Preview Generation.
    func previewURL(base: String) -> URL? {
        guard let preview = paths.preview else { return nil }
        if preview.hasPrefix("http") { return URL(string: preview) }
        return URL(string: "\(base.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(preview)")
    }
}

extension BingeScene {
    /// The one stash-box binge can ask who is in a scene. A match
    /// against any other box is not the identification the Home rule is
    /// about, because nothing can be looked up from it.
    ///
    /// Declared here rather than reused from StashDBService so it stays
    /// free of actor isolation; AddSceneService and FollowService each
    /// keep their own private copy of the same literal.
    static let stashDBEndpoint = "https://stashdb.org/graphql"

    /// This scene's StashDB id, if StashDB has matched it. Nil for a
    /// scene binge cannot identify, which is the whole test the Home
    /// feed applies to a scene with no performers linked.
    var stashDBSceneID: String? {
        stashIds?.first { $0.endpoint == BingeScene.stashDBEndpoint }?
            .stashId
    }

    /// Whether this scene may appear in the Home feed on its own
    /// merits. A linked performer is identification enough; failing
    /// that, StashDB must have matched it, and then its cast can be
    /// looked up and put on the card.
    var isIdentified: Bool {
        !performers.isEmpty || stashDBSceneID != nil
    }
}

struct FindScenesResponse: Decodable {
    let findScenes: Payload
    struct Payload: Decodable {
        let count: Int
        let scenes: [BingeScene]
    }
}
