import XCTest

@testable import SceneLogic

/// A baseline for the scene player's stream routing.
///
/// These tests do not describe an aspiration. They describe what the
/// player does TODAY, after a long stretch of tuning against a real
/// library, and their job is to say so loudly the moment it changes.
/// Every case below is a decision that was arrived at by something
/// breaking: HEVC going direct, VP9 going to MP4 rather than HLS, MKV
/// never going direct at all.
///
/// So: a failure here is not automatically a bug in the test. It means
/// someone changed the routing. If that was deliberate, change the
/// expectation and say why in the commit. If it was not, this caught
/// what nothing else in the project can - there is no test target in
/// the Xcode app, and this machine has no iOS simulator runtime, so
/// nothing touching AVFoundation or SwiftUI is reachable from here.
final class StreamRoutingTests: XCTestCase {
    // MARK: - Builders

    /// Stash's real advertisement: a direct entry FIRST, whose mime for
    /// an .mp4 source is itself video/mp4, then the transcode ladder.
    /// The ordering matters - it is what made an earlier "prefer mp4"
    /// match hand back the direct stream.
    private func streams(
        direct: String = "video/mp4"
    ) -> [BingeScene.SceneStream] {
        [
            .init(
                url: "/scene/1/stream",
                label: "Direct stream",
                mimeType: direct
            ),
            .init(
                url: "/scene/1/stream.mp4",
                label: "MP4 HD (720p)",
                mimeType: "video/mp4"
            ),
            .init(
                url: "/scene/1/stream.m3u8",
                label: "HLS",
                mimeType: "application/vnd.apple.mpegurl"
            ),
            .init(
                url: "/scene/1/stream.webm",
                label: "WEBM",
                mimeType: "video/webm"
            ),
        ]
    }

    private func scene(
        codec: String?,
        path: String = "/library/a.mp4",
        streams s: [BingeScene.SceneStream]? = nil,
        stream: String? = "/scene/1/stream"
    ) -> BingeScene {
        BingeScene(
            id: "1",
            title: "A scene",
            details: nil,
            oCounter: nil,
            playCount: nil,
            rating100: nil,
            createdAt: nil,
            date: nil,
            paths: .init(stream: stream, screenshot: nil, preview: nil),
            files: [
                .init(
                    duration: 10,
                    width: 1920,
                    height: 1080,
                    videoCodec: codec,
                    audioCodec: nil,
                    frameRate: nil,
                    size: nil,
                    bitRate: nil,
                    path: path
                )
            ],
            sceneStreams: s ?? streams(),
            performers: [],
            studio: nil,
            tags: [],
            stashIds: nil
        )
    }

    private func url(_ s: BingeScene, _ pref: String = "auto") -> String? {
        UserDefaults.standard.set(pref, forKey: "binge.transcodeType")
        return s.streamURL(base: "http://box:9999")?.absoluteString
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "binge.transcodeType")
        super.tearDown()
    }

    // MARK: - The auto routing table

    func testH264GoesDirect() {
        // The whole point of the direct path: no ffmpeg load for the
        // codec that streams cleanly everywhere.
        XCTAssertEqual(
            url(scene(codec: "h264")),
            "http://box:9999/scene/1/stream"
        )
    }

    func testHEVCGoesDirect() {
        // Deliberate, and the opposite of what the file's own header
        // comment used to claim. The phone hardware-decodes what this
        // library's pipeline produces, and at ~1.4 Mbps direct is
        // FEWER bytes over the link than Stash's H.264 transcode.
        // Sending HEVC to a transcode instead would be a regression
        // even though it would still play.
        XCTAssertEqual(
            url(scene(codec: "hevc")),
            "http://box:9999/scene/1/stream"
        )
        XCTAssertEqual(
            url(scene(codec: "h265")),
            "http://box:9999/scene/1/stream"
        )
    }

    func testVP9GoesToMP4LadderNotHLS() {
        // VP9 to HLS black-screened about one clip in ten and did not
        // recover on rebuild. MP4 is the settled answer.
        XCTAssertEqual(
            url(scene(codec: "vp9")),
            "http://box:9999/scene/1/stream.mp4"
        )
    }

    func testAV1AndUnknownCodecsTranscode() {
        XCTAssertEqual(
            url(scene(codec: "av1")),
            "http://box:9999/scene/1/stream.mp4"
        )
        XCTAssertEqual(
            url(scene(codec: "mpeg4")),
            "http://box:9999/scene/1/stream.mp4"
        )
    }

    func testMissingCodecTranscodesRatherThanGuessing() {
        // needsTranscode returns TRUE for a nil codec on purpose:
        // better a transcode than a black screen. This is also why
        // dropping `files` from the feed queries to save bytes is
        // self-defeating - every scene would land here, and every
        // scene would then need the sceneStreams array.
        XCTAssertTrue(scene(codec: nil).needsTranscode)
        XCTAssertEqual(
            url(scene(codec: nil)),
            "http://box:9999/scene/1/stream.mp4"
        )
    }

    func testMKVPrefersHLSAndOverridesEverything() {
        // AVFoundation cannot demux the container at all, so an
        // H.264-in-MKV file fails direct playback just as an HEVC one
        // does. The MKV branch therefore sits ABOVE both the codec
        // routing and the user's preference, and prefers HLS.
        //
        // I got this wrong when writing the baseline - I assumed the
        // MP4 ladder - and the test caught it. Leaving the note
        // because "MKV goes to MP4" is the intuitive wrong answer.
        let mkv = scene(codec: "hevc", path: "/library/a.mkv")
        XCTAssertTrue(mkv.isMKV)
        XCTAssertEqual(url(mkv), "http://box:9999/scene/1/stream.m3u8")

        // Even an H.264 MKV, which would otherwise go direct.
        let h264mkv = scene(codec: "h264", path: "/library/a.mkv")
        XCTAssertEqual(url(h264mkv), "http://box:9999/scene/1/stream.m3u8")

        // And even when the user explicitly asked for direct. This is
        // the one place a user preference is deliberately ignored, so
        // a refactor that "respects the setting" would break it.
        XCTAssertEqual(
            url(mkv, "direct"),
            "http://box:9999/scene/1/stream.m3u8"
        )
    }

    func testMKVWithNoTranscodeAdvertisedFallsBackToMP4ThenDirect() {
        // The ladder inside the MKV branch: HLS, then MP4, then direct
        // as a last resort that will probably fail but beats nil.
        let noHLS: [BingeScene.SceneStream] = [
            .init(url: "/d", label: "Direct stream", mimeType: "video/x-matroska"),
            .init(url: "/m", label: "MP4 HD (720p)", mimeType: "video/mp4"),
        ]
        XCTAssertEqual(
            url(scene(codec: "h264", path: "/a.mkv", streams: noHLS)),
            "http://box:9999/m"
        )
        XCTAssertEqual(
            url(scene(codec: "h264", path: "/a.mkv", streams: [])),
            "http://box:9999/scene/1/stream"
        )
    }

    // MARK: - Explicit preferences

    func testForcingATranscodeNeverReturnsTheDirectStream() {
        // The setting exists for the person whose direct stream will
        // not decode. Handing them the direct stream anyway is the
        // worst possible answer, and it is what happened when a mime
        // clause matched the direct entry - whose mime for an .mp4
        // source IS video/mp4, and which Stash lists first.
        for pref in ["mp4", "webm", "hls"] {
            let got = url(scene(codec: "hevc"), pref)
            XCTAssertNotEqual(
                got,
                "http://box:9999/scene/1/stream",
                "preference \(pref) returned the direct stream"
            )
        }
    }

    func testEachPreferencePicksItsOwnStream() {
        XCTAssertEqual(
            url(scene(codec: "h264"), "mp4"),
            "http://box:9999/scene/1/stream.mp4"
        )
        XCTAssertEqual(
            url(scene(codec: "h264"), "webm"),
            "http://box:9999/scene/1/stream.webm"
        )
        XCTAssertEqual(
            url(scene(codec: "h264"), "hls"),
            "http://box:9999/scene/1/stream.m3u8"
        )
        XCTAssertEqual(
            url(scene(codec: "hevc"), "direct"),
            "http://box:9999/scene/1/stream"
        )
    }

    func testAnUnrecognisedLabelFallsBackRatherThanFailing() {
        // preferredStream matches labels by EXACT equality, despite a
        // doc comment elsewhere claiming case-insensitive substring.
        // That is worth pinning both ways: a Stash that renames or
        // re-cases its labels silently degrades to the direct stream
        // rather than erroring, so "forced MP4" quietly stops forcing
        // anything. If this test ever starts failing because someone
        // made the match lenient, that is an improvement - update it.
        let renamed: [BingeScene.SceneStream] = [
            .init(url: "/d", label: "Direct stream", mimeType: "video/mp4"),
            .init(url: "/t", label: "mp4 hd (720p)", mimeType: "video/mp4"),
        ]
        let s = scene(codec: "vp9", streams: renamed)
        XCTAssertEqual(url(s), "http://box:9999/scene/1/stream")
    }

    func testStallRecoveryPrefersHLSAndExistsForHEVC() {
        // HEVC plays direct, so the non-faststart minority stall - and
        // this is the only way back. nil here means a stalled scene
        // stays stalled.
        let s = scene(codec: "hevc")
        XCTAssertEqual(
            s.transcodeFallbackURL(base: "http://box:9999")?.absoluteString,
            "http://box:9999/scene/1/stream.m3u8"
        )
    }

    func testNoTranscodeAdvertisedStillYieldsSomethingPlayable() {
        // A Stash with transcoding off advertises no ladder. Routing
        // must fall back to the direct stream rather than returning
        // nil, which would render an empty player.
        let s = scene(codec: "vp9", streams: [])
        XCTAssertEqual(url(s), "http://box:9999/scene/1/stream")
        XCTAssertNil(s.transcodeFallbackURL(base: "http://box:9999"))
    }

    // MARK: - The decode contract

    func testDroppingSceneStreamsFromAQueryBreaksTheWholeResponse() {
        // sceneStreams is a non-optional `let`, so a query that stops
        // selecting it does not degrade gracefully - the decode throws
        // and the ENTIRE response is lost. On Home that is an empty
        // feed, not a feed with slightly worse playback.
        //
        // This is pinned because dropping that field looks like an
        // easy 9.7 MB saving and is the single most tempting change
        // anyone will propose against this file. The saving is also
        // mostly imaginary: the payload is gzipped on the wire.
        let withField = """
            {"id":"1","title":null,"details":null,"created_at":null,
             "date":null,"paths":{"stream":"/s","screenshot":null,
             "preview":null},"files":[],"sceneStreams":[],
             "performers":[],"studio":null,"tags":[]}
            """
        XCTAssertNoThrow(
            try JSONDecoder().decode(
                BingeScene.self, from: Data(withField.utf8))
        )

        let without = withField.replacingOccurrences(
            of: "\"sceneStreams\":[],", with: "")
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                BingeScene.self, from: Data(without.utf8)),
            "sceneStreams became optional - if that was deliberate, "
                + "every call site that assumed it was present needs "
                + "checking before this expectation is relaxed"
        )
    }

    // MARK: - Credentials

    func testALoggedStreamURLNeverCarriesTheAPIKey() {
        // Stash appends ?apikey=<JWT> to paths.stream and to every
        // sceneStreams url itself, so anything printing a whole stream
        // URL writes the user's full-access token to the device log.
        let raw = URL(
            string: "http://box:9999/scene/1/stream?apikey=SECRET&t=2")!
        let printed = BingeScene.redacted(raw)
        XCTAssertFalse(printed.contains("SECRET"), printed)
        XCTAssertTrue(printed.contains("/scene/1/stream"), printed)
    }
}
