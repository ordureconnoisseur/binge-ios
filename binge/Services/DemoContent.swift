import Foundation

/// Fictional, SFW library used in demo mode for App Store capture.
/// Everything here is invented — names, titles, studios — and the media
/// is procedural gradients (demo:// URLs), so nothing real ever appears.
enum DemoContent {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private struct Perf {
        let id: String
        let name: String
        /// Canonical scene count shown in Following + on the profile.
        /// Distinct per performer (Aria the heaviest) so the Following
        /// list reads like a real, varied library.
        let count: Int
    }
    // Single evocative names — clearly placeholder, no real-performer
    // collision. Aria carries the most scenes so she dominates the reel
    // and forms a pack on Home.
    private static let performers: [Perf] = [
        .init(id: "p1", name: "Aria", count: 12),
        .init(id: "p2", name: "Nova", count: 9),
        .init(id: "p3", name: "Sable", count: 8),
        .init(id: "p4", name: "Wren", count: 7),
        .init(id: "p5", name: "Juno", count: 6),
        .init(id: "p6", name: "Lux", count: 5),
        .init(id: "p7", name: "Echo", count: 4),
        .init(id: "p8", name: "Vesper", count: 3),
        .init(id: "p9", name: "Iris", count: 2),
        .init(id: "p10", name: "Sage", count: 1),
    ]
    private static let studios = ["Aurora Films", "Lumen Studio", "Demo Pictures"]

    private static func scene(
        id: String,
        title: String,
        perf: Perf,
        co: [Perf] = [],
        studio: String,
        tags: [String],
        hoursAgo: Double
    ) -> BingeScene {
        let when = Date().addingTimeInterval(-hoursAgo * 3600)
        // Caption @-mentions the co-stars (matches the web feed cards);
        // solo scenes just get a vibe line.
        let caption =
            co.isEmpty
            ? "✨ \(tags.first ?? "moment")"
            : "with "
                + co.map { "@\($0.name.lowercased())" }
                .joined(separator: " ") + " ✨"
        return BingeScene(
            id: id,
            title: title,
            details: caption,
            oCounter: Int(hoursAgo) % 5,
            createdAt: isoFormatter.string(from: when),
            date: dayFormatter.string(from: when),
            paths: .init(
                stream: DemoMode.mediaURL("s-\(id)"),
                screenshot: DemoMode.mediaURL("s-\(id)"),
                preview: DemoMode.mediaURL("s-\(id)")
            ),
            files: [
                .init(
                    duration: 30, width: 1080, height: 1920,
                    videoCodec: "h264", audioCodec: "aac", frameRate: 30,
                    size: nil, bitRate: nil, path: nil
                )
            ],
            sceneStreams: [],
            performers: ([perf] + co).map { p in
                .init(
                    id: p.id, name: p.name,
                    imagePath: DemoMode.mediaURL("a-\(p.id)"),
                    favorite: false, gender: "FEMALE"
                )
            },
            studio: .init(name: studio),
            tags: tags.enumerated().map {
                .init(id: "demoTag-\($0.offset)-\(id)", name: $0.element)
            }
        )
    }

    /// The full fictional library — each performer gets `count` scenes
    /// (Aria the most, so she dominates the reel and forms a pack on
    /// Home). Every scene but the performer's last rotates in a co-star
    /// for the @mention caption.
    static let scenes: [BingeScene] = {
        let titles = [
            "Golden Hour", "City Lights", "Studio Session", "Candid Moment",
            "Afternoon Light", "Neon Nights", "Backstage", "Sunset Drive",
            "First Light", "Close Up", "Daydream", "Soft Focus",
        ]
        let tagSets = [
            ["Golden Hour", "Outdoor"], ["City", "Portrait"],
            ["Studio", "Aesthetic"], ["Candid", "Portrait"],
            ["Aesthetic", "Solo"], ["Outdoor", "Candid"],
        ]
        var out: [BingeScene] = []
        for (pIdx, p) in performers.enumerated() {
            // Only Aria (index 0) clusters enough recent scenes to form
            // the single group post (packMinSize is 8); everyone else
            // gets a few individual scenes so the feed/reel stay full
            // without spawning extra group posts.
            let n = pIdx == 0 ? p.count : min(p.count, 3)
            for i in 1...n {
                let coIdx = (pIdx + i) % performers.count
                // Last scene of each performer is left solo for variety.
                let co =
                    (coIdx == pIdx || i == n) ? [] : [performers[coIdx]]
                out.append(
                    scene(
                        id: "\(p.id)-\(i)",
                        title: titles[(i - 1) % titles.count],
                        perf: p,
                        co: co,
                        studio: studios[(pIdx + i) % studios.count],
                        tags: tagSets[(pIdx + i) % tagSets.count],
                        // Cluster each performer's scenes in time; earlier
                        // performers are more recent, so Aria sits at the
                        // top of Home as a fresh pack.
                        hoursAgo: Double(pIdx) * 30 + Double(i) * 0.5
                    )
                )
            }
        }
        return out
    }()

    /// Display name for a demo performer id.
    static func performerName(_ id: String) -> String {
        performers.first { $0.id == id }?.name ?? "Performer"
    }

    /// Scenes featuring a given demo performer.
    static func scenes(forPerformer id: String) -> [BingeScene] {
        scenes.filter { s in s.performers.contains { $0.id == id } }
    }

    /// Fictional profile record for a demo performer.
    static func performerDetail(id: String) -> PerformerDetail {
        let name = performerName(id)
        let count = performers.first { $0.id == id }?.count
            ?? scenes(forPerformer: id).count
        return PerformerDetail(
            id: id,
            name: name,
            aliasList: [],
            favorite: false,
            imagePath: DemoMode.mediaURL("a-\(id)"),
            details: "Demo performer — entirely fictional, for App Store capture.",
            country: "US",
            birthdate: nil,
            hairColor: nil,
            eyeColor: nil,
            sceneCount: count,
            galleryCount: 0,
            oCounter: count * 3,
            rating100: 84,
            twitter: nil,
            instagram: "@\(name.lowercased()).demo",
            url: nil,
            urls: ["https://example.com/\(name.lowercased())"],
            stashIds: nil
        )
    }

    /// Demo performers for the Following tab (first two favourited so the
    /// Favourites section populates).
    static var performerSummaries: [PerformerSummary] {
        performers.enumerated().map { idx, p in
            PerformerSummary(
                id: p.id,
                name: p.name,
                imagePath: DemoMode.mediaURL("a-\(p.id)"),
                sceneCount: p.count,
                favorite: idx < 3
            )
        }
    }

    /// Fictional SFW tag chips for the Explore strip.
    static let tagScores: [InteractedTagsStore.TagScore] = {
        let names = [
            "Golden Hour", "Outdoor", "Portrait", "Aesthetic",
            "City", "Studio", "Candid", "Solo",
        ]
        let now = Date().timeIntervalSince1970 * 1000
        return names.enumerated().map { idx, n in
            InteractedTagsStore.TagScore(
                tagId: "demo-tag-\(idx)",
                tagName: n,
                score: Double(names.count - idx),
                lastSeenAt: now - Double(idx) * 1000
            )
        }
    }()

    /// A few fictional collections for the Saved tab — the two defaults
    /// (Favourites / Watch Later) plus user-made ones. Each is backed by
    /// a deterministic slice of the library via `collectionScenes`.
    static let collections: [CollectionDef] = [
        .init(
            name: "Favourites",
            tagName: CollectionsService.favouritesTagName,
            icon: .favourite, isDefault: true
        ),
        .init(
            name: "Watch Later",
            tagName: CollectionsService.watchLaterTagName,
            icon: .watchLater, isDefault: true
        ),
        .init(
            name: "Golden Hours", tagName: "Golden Hours 📁",
            icon: .generic, isDefault: false
        ),
        .init(
            name: "City Nights", tagName: "City Nights 📁",
            icon: .generic, isDefault: false
        ),
        .init(
            name: "Studio Days", tagName: "Studio Days 📁",
            icon: .generic, isDefault: false
        ),
    ]

    /// The full library reordered deterministically by a seed — used in
    /// the Explore demo so tapping a tag chip visibly reshuffles the grid
    /// (the underlying set is the same; only the order changes).
    static func scenes(orderedBy seed: String) -> [BingeScene] {
        func rank(_ id: String) -> UInt64 {
            var h: UInt64 = 1_469_598_103_934_665_603
            for b in (seed + id).utf8 {
                h ^= UInt64(b)
                h = h &* 1_099_511_628_211
            }
            return h
        }
        return scenes.sorted { rank($0.id) < rank($1.id) }
    }

    /// Deterministic pseudo-random scene subset for a collection, keyed
    /// by its tag name — each collection shows a different handful of the
    /// library (~40%), stable across launches.
    static func collectionScenes(for tagName: String) -> [BingeScene] {
        var seed: UInt64 = 1_469_598_103_934_665_603
        for b in tagName.utf8 {
            seed ^= UInt64(b)
            seed = seed &* 1_099_511_628_211
        }
        return scenes.enumerated().filter { idx, _ in
            (UInt64(idx) &* 2_654_435_761 &+ seed) % 5 < 2
        }.map(\.element)
    }
}
