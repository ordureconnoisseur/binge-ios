import SwiftUI

// Discovery card — surfaces a StashDB scene not yet in the user's
// library. Visually mirrors SceneFeedCard but with cues that flag
// it as external content:
//   - "Discover" / "Trending" badge in the header
//   - "View on StashDB" CTA in the action row (opens browser)
//
// v0.2 doesn't wire the follow / add-scene flows — those need a
// scrapeSinglePerformer + performerCreate mutation chain that's
// staged as Phase 2 of the StashDB integration. Header rendering
// still surfaces co-performer @mentions (read-only).
struct DiscoveryFeedCard: View {
    let item: DiscoveryItem
    /// Tap on the primary performer's avatar/name. The parent
    /// passes a closure that knows how to route — library
    /// performers go to PerformerProfileSheet, StashDB-only
    /// performers (no localId) go to StashDBPerformerProfile.
    let onPerformerTap: (DiscoveryItem.Performer) -> Void

    /// Local Stash scene id assigned by sceneCreate. Non-nil
    /// means the scene was added in this session — drives the
    /// "in library" badge + the menu's "Open in Stash" item.
    /// Parent (HomeView) reads it from
    /// `HomeViewModel.addedSceneLocalIds[item.sceneStashId]`
    /// so the state survives LazyVStack re-creation.
    let addedLocalId: String?
    private var sceneAdded: Bool { addedLocalId != nil }

    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    private var apiKey: String { KeychainStore.shared.stashApiKey }

    /// Error surface for the add flow. nil = idle. Local because
    /// the error is fleeting — once dismissed (by another tap or
    /// the next mount) it should go away. Persistence not
    /// needed.
    @State private var addError: String?
    /// A sceneCreate is in flight. Guards the only write on this card.
    @State private var adding = false
    /// Derived performer slices, computed once per item rather
    /// than on every body render. Plain `var` (computed
    /// properties) would re-filter / re-sort / re-join on every
    /// SwiftUI body diff — these slices are stable for the life
    /// of an item, so we cache and refresh in .task(id: item.id).
    @State private var stackPerformers: [DiscoveryItem.Performer] = []
    @State private var unlinkedCoPerformers: [DiscoveryItem.Performer] = []

    #if DEBUG
    /// Whether the configured forage daemon is reachable — gates the
    /// "Send to forage" menu item so it's invisible when forage isn't
    /// running. Backed by a shared probe (ForageReachability) so the
    /// whole feed shares one /healthz call.
    @State private var forageReachable = false
    @State private var forageStatus: ForageStatus = .idle
    private enum ForageStatus: Equatable {
        case idle, sending, sent(String), error(String)
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)
            cover
            caption
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 14)
        }
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
        // Populate the cached slices on first mount AND whenever
        // a different item gets swapped into this card cell
        // (LazyVStack reuses cells, so item.id can change without
        // a remount). .task(id:) handles both.
        .task(id: item.id) {
            rebuildDerived()
        }
        .task {
            #if DEBUG
            forageReachable = await ForageReachability.shared.reachable()
            #endif
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            AvatarStack(
                items: stackPerformers,
                size: 36,
                overlap: 14,
                visibleLimit: 3,
                resolveImage: { perf in
                    let url = perf.image.flatMap(URL.init(string:))
                    // StashDB images are public CDN URLs —
                    // empty apiKey skips the Stash ApiKey header.
                    return (url, "")
                },
                initial: { String($0.name.prefix(1)) },
                onTap: onPerformerTap
            )
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    onPerformerTap(item.primaryPerformer)
                } label: {
                    // Names + inline verified badges. Every entry
                    // in stackPerformers is by construction a
                    // library performer (the primary plus any
                    // linked co-performers); each gets a badge
                    // whose colour reflects favourite state.
                    HStack(
                        alignment: .firstTextBaseline,
                        spacing: 0
                    ) {
                        ForEach(
                            Array(stackPerformers.enumerated()),
                            id: \.element.id
                        ) { idx, p in
                            if idx > 0 {
                                Text(", ")
                                    .font(.system(
                                        size: 14, weight: .semibold
                                    ))
                                    .foregroundStyle(.white)
                            }
                            Text(p.name)
                                .font(.system(
                                    size: 14, weight: .semibold
                                ))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if p.localId != nil {
                                VerifiedBadge(
                                    favorite: p.favorite, size: 12
                                )
                                .padding(.leading, 3)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    Text(badgeText)
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.4)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(badgeColor.opacity(0.85))
                        )
                    if let date = formatReleaseDate(item.releaseDate) {
                        Text(date)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            Spacer()
            SceneCardMenu(items: menuItems)
        }
    }

    /// Discovery menu — matches the web's SceneCardMenu. Pre-add:
    /// "Add scene to library" + "View on StashDB". Post-add:
    /// just "View on StashDB".
    ///
    /// The comment here used to claim dropping the row on sceneAdded
    /// meant "a second tap can't fire a duplicate sceneCreate". It
    /// could: sceneAdded only turns true once the write has RETURNED,
    /// and the write is four round trips downstream of the tap. The
    /// in-flight flag is what actually closes that window.
    private var menuItems: [SceneCardMenu.Item] {
        var out: [SceneCardMenu.Item] = []
        if !sceneAdded && !adding {
            out.append(
                .init(
                    label: "Add scene to library",
                    systemImage: "plus.rectangle.on.rectangle",
                    sub: "Create the scene in Stash + link to StashDB"
                ) {
                    addToLibrary()
                }
            )
        }
        #if DEBUG
        if forageReachable {
            out.append(
                .init(
                    label: forageMenuLabel,
                    systemImage: "tray.and.arrow.down",
                    sub: forageMenuSub
                ) {
                    sendToForage()
                }
            )
        }
        #endif
        out.append(
            .init(
                label: "View on StashDB",
                systemImage: "arrow.up.right.square",
                sub: "Opens in Safari"
            ) {
                openStashDB()
            }
        )
        return out
    }

    #if DEBUG
    private var forageMenuLabel: String {
        switch forageStatus {
        case .sending: return "Sending to forage…"
        case .sent: return "On forage watchlist"
        default: return "Send to forage"
        }
    }

    private var forageMenuSub: String {
        if case let .sent(target) = forageStatus {
            return target == "any"
                ? "Watching for any release"
                : "Watching for a \(target) copy"
        }
        return "Add to your forage watchlist"
    }

    /// Adds the discovery scene to forage's watchlist via POST /watches.
    /// The menu closes on tap, so the outcome surfaces inline in the
    /// caption (see `forageStatusLine`).
    private func sendToForage() {
        if case .sending = forageStatus { return }
        if case .sent = forageStatus { return }
        forageStatus = .sending
        Task {
            let result = await ForageService.addWatch(
                .init(
                    stashdb_id: item.sceneStashId,
                    title: item.title ?? "",
                    date: item.releaseDate,
                    image_url: item.coverUrl,
                    performer_name: item.primaryPerformer.name,
                    performer_id: item.primaryPerformer.localId,
                    target: ForageService.currentTarget()
                )
            )
            await MainActor.run {
                switch result {
                case let .ok(target): forageStatus = .sent(target)
                case let .failure(msg): forageStatus = .error(msg)
                }
            }
        }
    }
    #endif

    private func openStashDB() {
        guard let url = URL(string: item.stashboxUrl) else { return }
        UIApplication.shared.open(url)
    }

    private func addToLibrary() {
        // sceneAdded is not a guard. It is a prop the parent derives
        // from the bingeSceneAdded notification, which AddSceneService
        // posts only AFTER sceneCreate returns - and the write is
        // preceded by four sequential round trips, two of them
        // whole-library scans. So from the first tap the user was two
        // taps from a duplicate: the menu row is still rendered,
        // nothing is disabled, and Stash does not enforce stash_id
        // uniqueness on scenes. Each extra press left another fileless
        // row carrying the same stash_id, another stored cover blob,
        // and a scene binge never surfaces again - so cleanup is
        // manual.
        if adding { return }
        adding = true
        Task {
            defer { adding = false }
            let svc = AddSceneService(baseURL: baseURL, apiKey: apiKey)
            do {
                _ = try await svc.addStashDBScene(
                    stashId: item.sceneStashId,
                    title: item.title,
                    coverUrl: item.coverUrl,
                    stashboxUrl: item.stashboxUrl
                )
                // sceneAdded flips via the bingeSceneAdded
                // notification → HomeViewModel.addedSceneLocalIds
                // → re-render with the new prop.
                addError = nil
            } catch {
                // Surface the actual Stash error so the user can
                // see what's wrong — generic "try again" hides
                // schema validation failures (e.g. cover_image
                // URL rejected, missing required field, etc.).
                let msg = (error as? LocalizedError)?.errorDescription
                    ?? "\(error)"
                addError = "Add failed: \(msg)"
                print(
                    "[binge] add scene[\(item.sceneStashId)] "
                        + "failed: \(error)"
                )
            }
        }
    }

    /// Rebuild the cached performer slices from the current item.
    /// Called from .task(id: item.id) on mount and whenever the
    /// underlying item swaps. The slices feed:
    /// - stackPerformers: primary + library-linked co-performers
    ///   (shown as overlapping avatars in the header)
    /// - headerNames: comma-joined names matching the avatar stack
    /// - unlinkedCoPerformers: stashdb-only co-performers (shown
    ///   as @mentions below the cover)
    /// "Library performers get icons, StashDB-only performers get
    /// @mentions" mirrors the web layout.
    private func rebuildDerived() {
        var stack: [DiscoveryItem.Performer] = [item.primaryPerformer]
        var unlinked: [DiscoveryItem.Performer] = []
        for p in item.coPerformers {
            if p.localId != nil {
                stack.append(p)
            } else {
                unlinked.append(p)
            }
        }
        stackPerformers = stack
        unlinkedCoPerformers = unlinked
    }

    private var badgeText: String {
        switch item.source {
        case .costar: return "DISCOVER"
        case .trending: return "TRENDING"
        }
    }

    private var badgeColor: Color {
        // Both pills share the brand pink. The label text
        // (DISCOVER vs TRENDING) is the differentiator — keeps the
        // colour vocabulary tight. Matches the web's same-pink
        // treatment for the two pills.
        Color.bingeLike
    }

    // MARK: - Cover

    @ViewBuilder
    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color.black
                if let urlStr = item.coverUrl,
                    let url = URL(string: urlStr)
                {
                    AuthImageView(
                        url: url,
                        apiKey: "",
                        contentMode: .fill,
                        maxPixel: 1200
                    )
                }
                // No play glyph — discovery scenes aren't
                // playable in-app (they're StashDB references,
                // not Stash library files). The "View on
                // StashDB" CTA below makes the affordance clear
                // instead.
                Image(systemName: "rectangle.stack.fill.badge.plus")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
                    .shadow(radius: 4)
            }
            if sceneAdded {
                Label("IN LIBRARY", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(Color.bingeVerified.opacity(0.95))
                    )
                    .padding(10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .animation(.snappy(duration: 0.25), value: sceneAdded)
    }

    // MARK: - Caption

    @ViewBuilder
    private var caption: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = item.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !unlinkedCoPerformers.isEmpty {
                mentionRow
            }
            if let url = URL(string: item.stashboxUrl) {
                Link(destination: url) {
                    Text("View on StashDB →")
                        .font(.system(size: 13))
                        // Muted white — matches web's
                        // .binge-discovery-card-stashdb-link
                        // (rgba(255,255,255,0.55)). Blue here
                        // pulled too hard against the title.
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.top, 2)
            }
            if let err = addError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.85))
                    .padding(.top, 2)
            }
            #if DEBUG
            forageStatusLine
            #endif
        }
    }

    #if DEBUG
    @ViewBuilder
    private var forageStatusLine: some View {
        switch forageStatus {
        case .sending:
            Text("Sending to forage…")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 2)
        case let .sent(target):
            Text(
                target == "any"
                    ? "On forage watchlist ✓"
                    : "On forage watchlist · \(target) ✓"
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color.green.opacity(0.9))
            .padding(.top, 2)
        case let .error(msg):
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.85))
                .padding(.top, 2)
        case .idle:
            EmptyView()
        }
    }
    #endif

    /// `with @name1 @name2` row — ONLY StashDB-only co-performers.
    /// Library-linked co-performers are shown as avatars in the
    /// header stack instead. Blue tap color matches web's
    /// `binge-performer-mention`.
    @ViewBuilder
    private var mentionRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("with")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                ForEach(unlinkedCoPerformers, id: \.id) { perf in
                    Button {
                        onPerformerTap(perf)
                    } label: {
                        Text("@\(perf.name)")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.bingeLink)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    /// StashDB release_date format is YYYY-MM-DD. Compact
    /// "D MMM YYYY" so a wide range of dates fits in the
    /// header line.
    private func formatReleaseDate(_ raw: String?) -> String? {
        guard let raw, raw.count >= 10 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: String(raw.prefix(10))) else {
            return nil
        }
        let out = DateFormatter()
        out.dateFormat = "d MMM yyyy"
        return out.string(from: d)
    }
}
