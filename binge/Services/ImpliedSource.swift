import Foundation

/// Working out what a scene with nobody linked belongs to.
///
/// A scene reaches the feed only if it is identified, and when StashDB
/// named nobody the remaining evidence is the studio, or failing that
/// the folder it was imported into, which is usually named after
/// whoever or whatever the import came from.
///
/// The hard part is knowing where the library ends and the meaningful
/// part of the path begins. A fixed list of folder names cannot know
/// that: it works for whoever wrote the list and turns
/// "/home/bob/media/Vixen/a.mp4" into "bob" for everybody else, which
/// would then collapse that person's entire library into one batch
/// named after them. So the root is measured, not guessed. Whatever
/// every path shares is the library; only what is below it names
/// anything.
///
/// This is a heuristic, and it is used only to GROUP and LABEL cards.
/// Nothing is ever written back to Stash. The worst case is a card
/// labelled after a folder rather than a person.
///
/// Mirrors web's `src/home/impliedSource.ts`.
struct ImpliedSource {
    /// Folder names that describe a library rather than a source, used
    /// only AFTER the shared root has been removed. Being short and
    /// generic is the point: measuring the root does the real work, and
    /// this only catches a bucket that some scenes sit in and others do
    /// not, like "Unfiled".
    ///
    /// A default, not a rule. Anyone whose layout uses a word that is
    /// not here, or who has a folder legitimately called "New",
    /// replaces the list in Settings.
    static let defaultLibraryFolderNames: [String] = [
        "media", "video", "videos", "movies", "scenes", "clips",
        "porn", "adult", "unfiled", "unsorted", "sorted", "misc",
        "other", "new", "downloads", "download", "complete",
        "completed", "incoming", "library",
    ]

    private let depthByRoot: [String: Int]
    private let containers: Set<String>

    /// `paths` is every file path in the batch being rendered, which is
    /// what makes measuring the root possible at all.
    init(
        paths: [String],
        libraryFolderNames: [String] = defaultLibraryFolderNames
    ) {
        containers = Set(
            libraryFolderNames
                .map {
                    $0.trimmingCharacters(in: .whitespaces).lowercased()
                }
                .filter { !$0.isEmpty }
        )

        // Group by first segment first, so a library spread over two
        // drives keeps a sensible root for each rather than falling
        // back to no shared root at all.
        var byRoot: [String: [[String]]] = [:]
        for path in paths {
            let folders = Self.folders(of: path)
            guard let root = folders.first else { continue }
            byRoot[root, default: []].append(folders)
        }
        var depths: [String: Int] = [:]
        for (root, group) in byRoot {
            depths[root] = Self.sharedDepth(group)
        }
        depthByRoot = depths
    }

    /// The studio when Stash knows one, since that is a curated field
    /// rather than a guess at a folder. Otherwise the first meaningful
    /// folder below the measured library root. Nil when the path says
    /// nothing useful, in which case the scene is never grouped.
    func resolve(studioName: String?, filePath: String?) -> String? {
        if let studio = studioName?.trimmingCharacters(in: .whitespaces),
            !studio.isEmpty
        {
            return studio
        }
        guard let filePath else { return nil }
        let folders = Self.folders(of: filePath)
        guard let root = folders.first else { return nil }
        let depth = depthByRoot[root] ?? 0
        for segment in folders.dropFirst(depth) {
            if Self.isRootSegment(segment) { continue }
            if containers.contains(segment.lowercased()) { continue }
            return segment
        }
        // Everything below the shared root was a container, so the file
        // sits in the library root and nothing names it.
        return nil
    }

    // MARK: - Path arithmetic

    /// The folders of a path, filename dropped. Windows and Unix
    /// layouts both reach here, and a Windows path survives a round
    /// trip through Stash with its backslashes intact.
    static func folders(of path: String) -> [String] {
        let segments = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return segments.isEmpty ? [] : Array(segments.dropLast())
    }

    /// A segment that is only a drive letter or a root marker.
    private static func isRootSegment(_ segment: String) -> Bool {
        if segment.hasPrefix("$") { return true }
        if segment.allSatisfy({ $0 == "." }) { return true }
        // "C:" and friends.
        if segment.count == 2, segment.hasSuffix(":"),
            segment.first?.isLetter == true
        {
            return true
        }
        return false
    }

    /// How many leading folders every path under a given root shares.
    /// Capped so at least one folder always survives, or a library
    /// whose scenes all sit in one directory would resolve to nothing.
    private static func sharedDepth(_ paths: [[String]]) -> Int {
        guard let shortest = paths.map(\.count).min() else { return 0 }
        let cap = shortest - 1
        guard cap > 0 else { return 0 }
        var depth = 0
        while depth < cap {
            let segment = paths[0][depth]
            if paths.contains(where: { $0[depth] != segment }) { break }
            depth += 1
        }
        return depth
    }
}

/// The folder-name list, as a setting rather than a constant. Which
/// intermediate buckets exist is a property of one person's disk, so it
/// is theirs to set; the default above is only a starting point.
///
/// Stored comma-separated. An empty stored value means "none", which is
/// distinct from never having set one.
enum LibraryFolderNamesStore {
    static let storageKey = "binge.libraryFolderNames"

    static let defaultsRaw: String = ImpliedSource
        .defaultLibraryFolderNames
        .joined(separator: ", ")

    static func current() -> [String] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey)
        else { return ImpliedSource.defaultLibraryFolderNames }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
