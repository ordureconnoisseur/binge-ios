import SwiftUI

/// Bulk-import card. Renders as a single feed entry when binge
/// detects many scenes from the same performer added in one
/// batch. The cover is a 3×3 mosaic of the newest scene
/// screenshots; tap any tile to open the pack sheet listing
/// every scene.
///
/// Header chrome matches SceneFeedCard so the cards read as
/// siblings — story ring around the primary's avatar when she
/// has a fresh story, plus a relative timestamp on the second
/// line. Mirrors web's `PackFeedCard.tsx`.
struct PackFeedCard: View {
    let pack: SceneFeedPack
    /// Map of performerId → currently-active Story. Drives the
    /// gradient ring overlay + routes avatar taps into the
    /// story viewer instead of the profile sheet. Caller passes
    /// HomeViewModel's cached map verbatim.
    let storiesByPerformerId: [String: Story]
    /// Tap on the primary avatar when she has a story →
    /// route to the home story viewer at this story's index.
    let onStoryTap: (Story) -> Void
    /// Tile tap inside the pack detail sheet. HomeView wires
    /// this up to the cover-reel handoff so a scene tap inside
    /// the pack pops up the deterministic timeline reel.
    var onSceneTap: ((BingeScene) -> Void)? = nil

    /// Number of cover tiles rendered in the 3×3 mosaic. The
    /// pack may hold dozens or hundreds of scenes; the grid
    /// surfaces only the first 9 (newest-first) and the "+N
    /// more" badge counts the remainder.
    private static let mosaicTiles: Int = 9

    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    private var apiKey: String { KeychainStore.shared.stashApiKey }

    @State private var sheetOpen: Bool = false
    @State private var presentedPerformerId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)
            mosaic
        }
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
        .sheet(isPresented: $sheetOpen) {
            PackDetailSheet(pack: pack, onSceneTap: onSceneTap)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { presentedPerformerId != nil },
                set: { if !$0 { presentedPerformerId = nil } }
            )
        ) {
            if let id = presentedPerformerId {
                PerformerProfileSheet(performerId: id)
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        // A batch with nobody linked locally has no profile to open and
        // no story to drop into, so the taps are inert for it.
        let story = pack.primaryPerformer
            .flatMap { storiesByPerformerId[$0.id] }
        HStack(spacing: 10) {
            Button {
                if let story {
                    onStoryTap(story)
                } else {
                    presentedPerformerId = pack.primaryPerformer?.id
                }
            } label: {
                avatarBubble(hasStory: story != nil)
            }
            .buttonStyle(.plain)
            .disabled(pack.primaryPerformer == nil && story == nil)

            Button {
                presentedPerformerId = pack.primaryPerformer?.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(
                        alignment: .firstTextBaseline, spacing: 0
                    ) {
                        Text(pack.label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let primary = pack.primaryPerformer {
                            VerifiedBadge(
                                favorite: primary.favorite,
                                size: 12
                            )
                            .padding(.leading, 3)
                        } else {
                            // Named by StashDB, not in the library. Says
                            // the identity is missing locally rather
                            // than implying a profile that is not there.
                            NotInLibraryBadge(size: 12)
                                .padding(.leading, 3)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(
                            pack.isRepost
                                ? "reposted \(pack.sceneCount) scenes"
                                : "added \(pack.sceneCount) new scenes"
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.35))
                        Text(RelativeDate.relative(pack.effectiveAt))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    @ViewBuilder
    private func avatarBubble(hasStory: Bool) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.18))
            if let path = pack.primaryPerformer?.imagePath,
                let url = URL(string: absolute(path))
            {
                AuthImageView(
                    url: url,
                    apiKey: apiKey,
                    contentMode: .fill,
                    maxPixel: 256,
                    alignment: .top
                )
            } else if let remote = pack.matchedPerformer?.image,
                let url = URL(string: remote)
            {
                // StashDB's own image. It is not proxied through Stash,
                // so it needs no api key.
                AuthImageView(
                    url: url,
                    apiKey: "",
                    contentMode: .fill,
                    maxPixel: 256,
                    alignment: .top
                )
            } else {
                Text(
                    String(pack.label.prefix(1))
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(Circle())
        .overlay(
            Group {
                if hasStory {
                    Circle().strokeBorder(
                        LinearGradient.bingeStoryRing,
                        lineWidth: 2
                    )
                } else {
                    Circle().stroke(Color.black, lineWidth: 2)
                }
            }
        )
        .overlay(alignment: .bottomTrailing) {
            if pack.isRepost {
                RepostBadge()
            }
        }
    }

    @ViewBuilder
    private var mosaic: some View {
        let tiles = Array(pack.scenes.prefix(Self.mosaicTiles))
        let overflow = pack.sceneCount - tiles.count
        Button { sheetOpen = true } label: {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let tileSide = (geo.size.width - gap * 2) / 3
                VStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { row in
                        HStack(spacing: gap) {
                            ForEach(0..<3, id: \.self) { col in
                                let i = row * 3 + col
                                if i < tiles.count {
                                    tile(
                                        scene: tiles[i],
                                        showOverflow:
                                            i == Self.mosaicTiles - 1
                                            && overflow > 0,
                                        overflow: overflow
                                    )
                                    .frame(
                                        width: tileSide,
                                        height: tileSide
                                    )
                                } else {
                                    Color(white: 0.04)
                                        .frame(
                                            width: tileSide,
                                            height: tileSide
                                        )
                                }
                            }
                        }
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func tile(
        scene: BingeScene,
        showOverflow: Bool,
        overflow: Int
    ) -> some View {
        ZStack {
            Color(white: 0.04)
            if let url = scene.screenshotURL(base: baseURL) {
                AuthImageView(
                    url: url,
                    apiKey: apiKey,
                    contentMode: .fill,
                    maxPixel: 512
                )
            }
            if showOverflow {
                Color.black.opacity(0.62)
                Text("+\(overflow)")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
            }
        }
        .clipped()
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        let trimmed = baseURL.trimmingCharacters(
            in: .init(charactersIn: "/")
        )
        return "\(trimmed)\(path)"
    }
}
