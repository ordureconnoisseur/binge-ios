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

    private struct Perf { let id: String; let name: String }
    // Single evocative names — clearly placeholder, no real-performer
    // collision.
    private static let performers: [Perf] = [
        .init(id: "p1", name: "Aria"),
        .init(id: "p2", name: "Nova"),
        .init(id: "p3", name: "Sable"),
        .init(id: "p4", name: "Wren"),
        .init(id: "p5", name: "Juno"),
    ]
    private static let studios = ["Aurora Films", "Lumen Studio", "Demo Pictures"]

    private static func scene(
        id: String,
        title: String,
        perf: Perf,
        studio: String,
        tags: [String],
        hoursAgo: Double
    ) -> BingeScene {
        let when = Date().addingTimeInterval(-hoursAgo * 3600)
        return BingeScene(
            id: id,
            title: title,
            details: "A demo scene for App Store capture — entirely fictional.",
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
            performers: [
                .init(
                    id: perf.id, name: perf.name,
                    imagePath: DemoMode.mediaURL("a-\(perf.id)"),
                    favorite: false, gender: "FEMALE"
                )
            ],
            studio: .init(name: studio),
            tags: tags.enumerated().map {
                .init(id: "demoTag-\($0.offset)-\(id)", name: $0.element)
            }
        )
    }

    /// The full fictional library — one performer's bulk import (a pack
    /// card) plus singles from others (stories + feed cards + reel).
    static let scenes: [BingeScene] = {
        var out: [BingeScene] = []
        // Pack: Aria, 8 scenes within a few hours → collapses to a pack.
        for i in 1...8 {
            out.append(
                scene(
                    id: "aria-\(i)", title: "Golden Hour \(i)",
                    perf: performers[0], studio: studios[0],
                    tags: ["Golden Hour", "Outdoor"],
                    hoursAgo: 2 + Double(i) * 0.3
                )
            )
        }
        out.append(scene(id: "nova-1", title: "City Lights", perf: performers[1], studio: studios[1], tags: ["City", "Portrait"], hoursAgo: 5))
        out.append(scene(id: "sable-1", title: "Studio Session", perf: performers[2], studio: studios[2], tags: ["Studio", "Aesthetic"], hoursAgo: 9))
        out.append(scene(id: "wren-1", title: "Candid", perf: performers[3], studio: studios[0], tags: ["Candid", "Portrait"], hoursAgo: 26))
        out.append(scene(id: "juno-1", title: "Afternoon Light", perf: performers[4], studio: studios[1], tags: ["Aesthetic", "Solo"], hoursAgo: 50))
        return out
    }()
}
