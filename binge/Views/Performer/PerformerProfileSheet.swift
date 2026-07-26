import AVKit
import SwiftUI

// Full-screen performer profile. Direct port of the web's
// PerformerProfile layout (src/performer/PerformerProfile.tsx).
//
// Structure (top to bottom):
//   ─ Topbar: back chevron · name · ⋯
//   ─ Hero row: 96pt avatar (with IG gradient ring when there's a
//     story) on the left, 3-column stat block (SCENES / LIKES /
//     RATING) filling the rest of the row
//   ─ Bio block: name + ★ rate placeholder · a.k.a. aliases ·
//     "Country · YYYY · Hair · Eyes" attrs · 3-line details ·
//     link chips (Twitter / Instagram / Website)
//   ─ Full-width outlined Favourite/Favourited button
//   ─ SCENES | PHOTOS tabs with underlined active state
//   ─ 2-column 9:16 portrait scene grid
//
// v0.2 deferred from web: rate accessory (★), ⋯ more menu, photos
// tab content (renders an empty-state for now), StashDB mix-in.
struct PerformerProfileSheet: View {
    let performerId: String
    /// When true (the default), the body wraps content in its
    /// own NavigationStack — that path is used by legacy
    /// fullScreenCover call sites that need toolbar/title to
    /// render. When false (the BingeRoute push path), we rely
    /// on the OUTER NavigationStack to host the toolbar items
    /// so we don't get a nested stack.
    var wrapInNavigationStack: Bool = true

    @Environment(\.dismiss) private var dismiss
    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    private var apiKey: String { KeychainStore.shared.stashApiKey }
    /// Per-profile (but globally persisted) toggle for the
    /// StashDB scene mix-in. Off by default — surface in the
    /// pill next to the SCENES header. Matches the web's
    /// useIncludeStashDBInProfile semantics, and now its storage
    /// key too (was `binge.profileStashDB`; migrated at launch in
    /// BingeApp.migrateSettingsKeys).
    @AppStorage("binge.includeStashDBInProfile")
    private var showStashDB: Bool = false

    @State private var vm: PerformerProfileViewModel?
    @State private var tour = TourDirector.shared
    @State private var favHaptic = 0
    @State private var tab: ProfileTab = .scenes
    @State private var storyOpen: Bool = false
    /// PornHub video the user tapped — drives a fullScreenCover that
    /// streams the mp4 via the daemon proxy with a Save button.
    @State private var pornhubPlaying: BingeServerService.PornhubVideo?
    /// Inner NavigationStack path for cover-mode presentation.
    /// Lets a scene tile push a `.reel(.timeline(...))` route
    /// onto the profile's own nav stack so the dismiss
    /// transition is the native iOS pop (no black flash).
    /// In push-mode (`wrapInNavigationStack == false`) the
    /// NavigationLink falls through to the OUTER stack's path
    /// instead, so this state is unused.
    @State private var profilePath: [BingeRoute] = []

    enum ProfileTab: Hashable { case scenes, photos }

    // Story ring shared with StoryBubble + SceneFeedCard so every
    // story-marker across the app is the same gradient. See
    // LinearGradient.bingeStoryRing in HeartBurst.swift.
    private static var storyRing: LinearGradient {
        .bingeStoryRing
    }

    var body: some View {
        Group {
            if wrapInNavigationStack {
                // Cover-mode: own NavigationStack with its own
                // path so scene-tile taps push `.reel(...)`
                // onto an internal stack — dismiss transition
                // for the reel is the native pop instead of a
                // cover slide-down. Profile dismissal itself
                // uses the cover's interactive pull-down + the
                // chevron toolbar item (see `content` below);
                // the old `swipeRightToDismiss` modifier is
                // gone because its high-priority DragGesture
                // was eating the ScrollView's vertical scroll.
                NavigationStack(path: $profilePath) {
                    content
                        .bingeRouteDestinations()
                }
            } else {
                // Push-mode: outer NavigationStack provides
                // both interactive pop AND destination
                // handling. NavigationLink(value:) inside
                // `content` finds the outer path and appends
                // there.
                content
            }
        }
        .task {
            if vm == nil {
                vm = PerformerProfileViewModel(
                    performerId: performerId,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
            }
            await vm?.load()
            // Fold this performer's recent X media into the story
            // (lights the ring; X-only performers get one too).
            await vm?.loadXMedia()
            // PornHub videos fold into the scenes grid as tiles.
            await vm?.loadPornhub()
            // If the user had the toggle on already (from a
            // previous session), auto-fetch the StashDB scenes
            // now — provided the performer is actually linked.
            if showStashDB, vm?.performer?.stashDBId != nil {
                await vm?.loadStashDBScenes()
            }
        }
        .fullScreenCover(isPresented: $storyOpen) {
            if let s = vm?.story {
                StoryViewerSheet(
                    stories: [s],
                    startIndex: 0,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
            }
        }
        .fullScreenCover(item: $pornhubPlaying) { video in
            PornhubPlayerSheet(
                video: video,
                performerStashId: performerId
            )
        }
        // Scribe sheet — mounted INSIDE the fullScreenCover that
        // hosts this profile so it stacks above the cover.
        // SwiftUI's RootView-level sheet can't appear over a
        // fullScreenCover, so opening Write Review from the menu
        // there would silently no-op. Each cover that can launch
        // Scribe needs its own binding to the singleton.
        .sheet(item: scribePresentedBinding) { ref in
            ScribeModal(subjectRef: ref)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        // Walkthrough: favourite the performer / leave the profile. Only
        // the on-screen profile is mounted, so this targets the right one.
        .onChange(of: tour.tick) { _, _ in
            switch tour.command {
            case .performerFavourite:
                vm?.toggleFavourite()
            case .performerOpenScene:
                // Open one of this performer's videos — push a drilled
                // reel onto the cover's own stack (cover mode only).
                if wrapInNavigationStack, let first = vm?.scenes.first {
                    profilePath.append(
                        .reel(.timeline(
                            scenes: vm?.scenes ?? [first],
                            startId: first.id
                        ))
                    )
                }
            case .performerBack:
                dismiss()
            default:
                break
            }
        }
        .statusBarHidden(tour.isRunning)
        .bingeHaptic(.impact(weight: .light), trigger: favHaptic)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
                // Plain VStack here, not LazyVStack — the profile
                // has a fixed handful of sections. LazyVStack was
                // confusing the inner scenes grid's height
                // computation and producing overlapping cells.
                VStack(alignment: .leading, spacing: 0) {
                    if let vm {
                        if let p = vm.performer {
                            heroRow(p, story: vm.story)
                            bio(p)
                            favouriteButton(active: vm.favourite)
                            tabs
                            if tab == .scenes {
                                scenesSection(vm.scenes)
                                if vm.loadingMore {
                                    BingeLoading(compact: true)
                                        .padding(.vertical, 18)
                                }
                            } else {
                                photosPlaceholder
                            }
                        } else if vm.loading {
                            BingeLoading(minHeight: 240)
                                .padding(.top, 60)
                        } else if let msg = vm.error {
                            errorView(msg)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if wrapInNavigationStack {
                    // Cover-mode only: no outer NavigationStack
                    // is providing a back chevron, so render
                    // our own. In push-mode the system back
                    // button shows up automatically.
                    ToolbarItem(placement: .topBarLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(
                                    .system(
                                        size: 16,
                                        weight: .semibold
                                    )
                                )
                                .foregroundStyle(.white)
                        }
                    }
                }
                ToolbarItem(placement: .principal) {
                    // Custom title slot — name plus verified badge
                    // rendered as a single Text run so SwiftUI
                    // places the icon on the text's cap-height
                    // line. An HStack with a separate Image would
                    // bottom-align (HStack(.center) aligns
                    // bounding-box centres, but a Text's bounding
                    // box centre sits below the visual cap-height
                    // centre). The performer is always in library
                    // (this sheet only loads library performers),
                    // so the badge always renders; colour swaps
                    // between IG-blue and brand pink based on the
                    // favourite flag.
                    if let p = vm?.performer {
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(p.name)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            VerifiedBadge(favorite: p.favorite, size: 14)
                                .padding(.leading, 4)
                        }
                    } else {
                        Text(vm?.performer?.name ?? "")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // ⋯ menu — mirrors the web's
                    // PerformerMoreSheet items (Write review,
                    // Refresh, Open in Stash). Write review is
                    // gated on the stashScribe plugin being
                    // installed + enabled.
                    Menu {
                        if PluginContext.shared.hasPlugin(
                            PluginID.scribe
                        ) {
                            Button {
                                ScribeContext.shared.openPerformer(
                                    performerId
                                )
                            } label: {
                                Label(
                                    "Write review",
                                    systemImage: "pencil.line"
                                )
                            }
                        }
                        Button {
                            Task {
                                // Drop the loaded model so
                                // load() runs fresh instead of
                                // short-circuiting on
                                // `performer != nil`.
                                vm = nil
                                vm = PerformerProfileViewModel(
                                    performerId: performerId,
                                    baseURL: baseURL,
                                    apiKey: apiKey
                                )
                                await vm?.load()
                                await vm?.loadXMedia()
                                await vm?.loadPornhub()
                                // Recreating the VM dropped the
                                // StashDB mix-in; re-fetch it so the
                                // tiles don't vanish on refresh when
                                // the toggle is on (matches the
                                // initial .task gating).
                                if showStashDB,
                                    vm?.performer?.stashDBId != nil
                                {
                                    await vm?.loadStashDBScenes()
                                }
                            }
                        } label: {
                            Label(
                                "Refresh",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        Button {
                            let trimmed = baseURL.trimmingCharacters(
                                in: .init(charactersIn: "/")
                            )
                            guard let url = URL(
                                string:
                                    "\(trimmed)/performers/\(performerId)"
                            ) else { return }
                            UIApplication.shared.open(url)
                        } label: {
                            Label(
                                "Open in Stash",
                                systemImage: "arrow.up.right.square"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(
                                Color.white.opacity(0.08),
                                in: Circle()
                            )
                            .contentShape(Rectangle())
                    }
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// Bridges ScribeContext.shared.presented to a `.sheet(item:)`
    /// binding. Same shape as RootView's binding.
    private var scribePresentedBinding: Binding<SubjectRef?> {
        Binding(
            get: { ScribeContext.shared.presented },
            set: { ScribeContext.shared.presented = $0 }
        )
    }

    // MARK: - Hero row

    @ViewBuilder
    private func heroRow(_ p: PerformerDetail, story: Story?) -> some View {
        HStack(alignment: .center, spacing: 20) {
            avatar(p, hasStory: story != nil)
            statsRow(p)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func avatar(_ p: PerformerDetail, hasStory: Bool) -> some View {
        let size: CGFloat = 96
        let ringPadding: CGFloat = 3
        let outerSize = hasStory ? size + ringPadding * 2 + 4 : size

        Button {
            if hasStory { storyOpen = true }
        } label: {
            ZStack {
                if hasStory {
                    Circle()
                        .fill(Self.storyRing)
                        .frame(width: outerSize, height: outerSize)
                }
                avatarInner(p)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(
                            // 2pt black inset ring carves the gap
                            // between gradient + avatar (web does
                            // this with box-shadow: inset 0 0 0 2px
                            // #0a0a0a).
                            hasStory
                                ? Color.black
                                : Color.white.opacity(0.18),
                            lineWidth: hasStory ? 2 : 1
                        )
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasStory)
    }

    @ViewBuilder
    private func avatarInner(_ p: PerformerDetail) -> some View {
        // Gray circle always renders so the avatar slot has a
        // visible footprint even while the image is loading
        // (AuthImageView now returns Color.clear during load so
        // the background shows through).
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            if let path = p.imagePath,
               let url = URL(string: absolute(path)) {
                AuthImageView(
                    url: url,
                    apiKey: apiKey,
                    contentMode: .fill,
                    maxPixel: 512,
                    alignment: .top
                )
                .clipShape(Circle())
            } else {
                Text(String(p.name.prefix(1)))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private func statsRow(_ p: PerformerDetail) -> some View {
        HStack(spacing: 8) {
            stat(value: p.sceneCount, label: "Scenes")
            stat(value: p.oCounter, label: "Likes")
            ratingStat(rating100: p.rating100)
        }
        .frame(maxWidth: .infinity)
    }

    /// Rating uses the same chrome as the count stats but
    /// formats as "N.N" out of 10 (Stash stores 0–100 internally;
    /// "8.4" reads more naturally than "84"). nil → "—".
    @ViewBuilder
    private func ratingStat(rating100: Int?) -> some View {
        VStack(spacing: 3) {
            Text(formatRating(rating100))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
            Text("RATING")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private func formatRating(_ r: Int?) -> String {
        guard let r else { return "—" }
        let val = Double(r) / 10
        // Drop trailing .0 so an unfractional rating renders as
        // "8" instead of "8.0" — keeps the row compact.
        if val.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(val))
        }
        return String(format: "%.1f", val)
    }

    @ViewBuilder
    private func stat(value: Int?, label: String) -> some View {
        VStack(spacing: 3) {
            Text(formatStat(value))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    /// Mirrors web `formatStat` — k-abbreviates at 1000.
    private func formatStat(_ n: Int?) -> String {
        guard let n else { return "—" }
        if n >= 10_000 { return "\(String(format: "%.1f", Double(n) / 1000))k" }
        if n >= 1_000 {
            let s = String(format: "%.1f", Double(n) / 1000)
            return s.replacingOccurrences(of: ".0", with: "") + "k"
        }
        return String(n)
    }

    // MARK: - Bio

    @ViewBuilder
    private func bio(_ p: PerformerDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(p.name)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            if !p.aliasList.isEmpty {
                Text("a.k.a. \(p.aliasList.joined(separator: ", "))")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.white.opacity(0.6))
            }
            let attrs = attributeLine(p)
            if !attrs.isEmpty {
                Text(attrs)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.78))
            }
            if let details = p.details, !details.isEmpty {
                Text(details)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .padding(.top, 2)
            }
            let allUrls = collectLinkUrls(p)
            if !allUrls.isEmpty {
                PerformerLinks(urls: allUrls)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    /// Gather every URL associated with a library performer for
    /// the PerformerLinks chip row. Pulls from the deprecated
    /// `twitter` / `instagram` / `url` discrete fields (which
    /// some older Stash installs still populate) AND the modern
    /// `urls` array, normalizing twitter/instagram handles to
    /// full URLs so PerformerLinks' platform detection picks
    /// them up.
    private func collectLinkUrls(_ p: PerformerDetail) -> [String] {
        var out: [String] = []
        if let tw = p.twitter, !tw.isEmpty {
            out.append(normalize(handle: tw, host: "twitter.com"))
        }
        if let ig = p.instagram, !ig.isEmpty {
            out.append(normalize(handle: ig, host: "instagram.com"))
        }
        if let u = p.url, !u.isEmpty {
            out.append(u)
        }
        if let urls = p.urls {
            out.append(contentsOf: urls)
        }
        return out
    }

    /// "US · 2004 · Blonde · Hazel eyes" — joins each non-nil
    /// attribute with " · ". Mirrors web PerformerBio's logic.
    private func attributeLine(_ p: PerformerDetail) -> String {
        var parts: [String] = []
        if let c = p.country, !c.isEmpty { parts.append(c) }
        if let bd = p.birthdate,
           let year = bd.split(separator: "-").first {
            parts.append(String(year))
        }
        if let hair = p.hairColor, !hair.isEmpty { parts.append(hair) }
        if let eyes = p.eyeColor, !eyes.isEmpty {
            parts.append("\(eyes) eyes")
        }
        return parts.joined(separator: " · ")
    }

    private func normalize(handle: String, host: String) -> String {
        if handle.lowercased().hasPrefix("http") { return handle }
        let cleaned = handle.hasPrefix("@")
            ? String(handle.dropFirst())
            : handle
        return "https://\(host)/\(cleaned)"
    }

    // MARK: - Favourite

    @ViewBuilder
    private func favouriteButton(active: Bool) -> some View {
        Button {
            vm?.toggleFavourite()
            favHaptic += 1
        } label: {
            Text(active ? "Favourited" : "Favourite")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(active ? Color.white.opacity(0.10) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .padding(.bottom, 14)
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabs: some View {
        HStack(spacing: 0) {
            tabButton("Scenes", value: .scenes)
            tabButton("Photos", value: .photos)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private func tabButton(_ label: String, value: ProfileTab) -> some View {
        let active = tab == value
        Button { tab = value } label: {
            VStack(spacing: 0) {
                Text(label.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(
                        active
                            ? Color.white
                            : Color.white.opacity(0.55)
                    )
                    .padding(.vertical, 12)
                Rectangle()
                    .fill(active ? Color.white : Color.clear)
                    .frame(height: 2)
                    .cornerRadius(2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scenes section

    @ViewBuilder
    private func scenesSection(_ scenes: [BingeScene]) -> some View {
        let tiles = mergedSceneTiles()
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                // The sort menu doubles as the section header — its
                // label ("RECENT") makes a separate "SCENES (n)" title
                // redundant.
                sortMenu
                Spacer()
                stashDBToggle
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            if tiles.isEmpty {
                Text("No scenes")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                sceneGrid(tiles)
                    .padding(.bottom, 30)
            }
        }
    }

    /// Tagged-union tile so the grid can render library + StashDB
    /// scenes from one ForEach. Identity is unique across both
    /// (StashDB scene ids never collide with Stash scene ids — but
    /// we still namespace to be safe).
    enum SceneTile: Identifiable, Hashable {
        case library(BingeScene)
        case stashDB(StashDBScene)
        case pornhub(BingeServerService.PornhubVideo)
        var id: String {
            switch self {
            case .library(let s): return "lib:\(s.id)"
            case .stashDB(let s): return "sdb:\(s.id)"
            case .pornhub(let v): return "ph:\(v.id)"
            }
        }
        /// Date for the merge sort. library/stashDB prefer their
        /// release_date (library falls back to created_at); pornhub
        /// uses its upload time (createdUtc → ISO).
        var effectiveAt: String {
            switch self {
            case .library(let s): return Story.effectiveAt(for: s)
            case .stashDB(let s): return s.releaseDate ?? ""
            case .pornhub(let v):
                return ISO8601DateFormatter().string(
                    from: Date(
                        timeIntervalSince1970: Double(v.createdUtc)
                    )
                )
            }
        }
    }

    /// Merge library + (optional) StashDB scenes for this performer.
    /// The library list arrives already ordered by the server per the
    /// active sort. For "recent" we re-interleave both sources by
    /// effective date DESC (release date, falling back to created_at) —
    /// the only sort where StashDB scenes have a comparable key. Every
    /// other sort orders by a stat StashDB tiles don't carry (views /
    /// orgasms / rating), so we keep the server order and append the
    /// StashDB tiles at the end.
    private func mergedSceneTiles() -> [SceneTile] {
        guard let vm else { return [] }
        let lib = vm.scenes.map(SceneTile.library)
        let sdb = vm.stashDBScenes.map(SceneTile.stashDB)
        let ph = vm.pornhubVideos.map(SceneTile.pornhub)
        // On "recent" every source carries a comparable date, so
        // interleave all three. Other sorts order by a stat only
        // library tiles have (views/orgasms/rating), so keep the
        // server order and append the dateless-by-that-key sources.
        if vm.sort == .recent {
            return (lib + sdb + ph).sorted {
                $0.effectiveAt > $1.effectiveAt
            }
        }
        return lib + sdb + ph
    }

    /// Subtle sort dropdown alongside the SCENES header. Native
    /// SwiftUI Menu — reads as a quiet "Recent ⌄" label that opens
    /// a checklist of options. Selecting one reloads the grid under
    /// the new order via vm.setSort.
    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            ForEach(PerformerSceneSort.allCases) { option in
                Button {
                    Task { await vm?.setSort(option) }
                } label: {
                    if vm?.sort == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text((vm?.sort ?? .recent).label.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.7)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    /// Compact toggle alongside the SCENES header. Persisted
    /// globally so it stays consistent across performer profiles
    /// (matches the web's useIncludeStashDBInProfile pattern).
    @ViewBuilder
    private var stashDBToggle: some View {
        let on = showStashDB && (vm?.performer?.stashDBId != nil)
        let canEnable = vm?.performer?.stashDBId != nil
        Button {
            guard canEnable else { return }
            showStashDB.toggle()
            if showStashDB {
                Task { await vm?.loadStashDBScenes() }
            } else {
                vm?.clearStashDBScenes()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                Text("StashDB")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
            }
            .foregroundStyle(
                canEnable
                    ? (on ? Color.bingeLike : .white.opacity(0.6))
                    : .white.opacity(0.25)
            )
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(
                    on
                        ? Color.bingeLike.opacity(0.18)
                        : Color.white.opacity(0.06)
                )
            )
            .overlay(
                Capsule().stroke(
                    on
                        ? Color.bingeLike.opacity(0.5)
                        : Color.white.opacity(0.12),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .disabled(!canEnable)
    }

    // 2-column grid via LazyVStack of HStack rows. Cells size
    // themselves via `.containerRelativeFrame(.horizontal,
    // count: 2, spacing: 4)` — iOS 17 native API that divides the
    // scroll container's width into 2 equal columns and gives
    // each child one slot. Edge-to-edge (no horizontal padding),
    // IG-style.
    //
    // Lazy mount gives us the infinite-scroll hook: when a row
    // near the tail enters the viewport, its .onAppear fires and
    // triggers loadMore. VM's `loadingMore` / `!hasMore` guards
    // absorb redundant calls when multiple near-end rows mount in
    // quick succession.
    @ViewBuilder
    private func sceneGrid(_ tiles: [SceneTile]) -> some View {
        let rows = tiles.chunked(into: 2)
        LazyVStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { idx in
                let row = rows[idx]
                HStack(spacing: 4) {
                    ForEach(row, id: \.id) { tile in
                        sceneCell(tile)
                    }
                    if row.count == 1 {
                        Color.clear
                            .containerRelativeFrame(
                                .horizontal,
                                count: 2,
                                span: 1,
                                spacing: 4
                            )
                            .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    }
                }
                .onAppear {
                    // Trigger when within the last 3 rows of the
                    // current grid. loadMore() short-circuits if
                    // already loading or exhausted, so multi-fire
                    // (several rows mounting at once) is harmless.
                    // Only the library pager is fed here; stashdb
                    // tiles capped at 100 in one shot.
                    if idx >= rows.count - 3 {
                        Task { await vm?.loadMore() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sceneCell(_ tile: SceneTile) -> some View {
        switch tile {
        case .library(let scene):
            libraryCell(scene)
        case .stashDB(let scene):
            stashDBCell(scene)
        case .pornhub(let video):
            pornhubCell(video)
        }
    }

    /// PornHub tile — proxied thumbnail with an orange "PH" badge.
    /// Tapping opens a streaming player (mp4 via the daemon proxy)
    /// with a Save-to-Stash action. No hover-preview (iOS can't
    /// decode the webm preview the web uses), so the poster is the
    /// static thumbnail — same as a library cell's screenshot.
    @ViewBuilder
    private func pornhubCell(_ video: BingeServerService.PornhubVideo)
        -> some View
    {
        Button {
            pornhubPlaying = video
        } label: {
            ZStack(alignment: .topLeading) {
                Color(white: 0.08)
                if let thumb = BingeServerService.pornhubThumbUrl(
                    video.thumbUrl
                ), let url = URL(string: thumb) {
                    AuthImageView(
                        url: url,
                        apiKey: "",
                        contentMode: .fill,
                        maxPixel: 512
                    )
                }
                Text("PH")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color(
                            red: 1.0, green: 0.565, blue: 0.0
                        ))
                    )
                    .padding(6)
            }
            .containerRelativeFrame(
                .horizontal,
                count: 2,
                span: 1,
                spacing: 4
            )
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Duration badge mirrors the library tile's sort badge slot.
            .overlay(alignment: .bottomLeading) {
                if video.duration > 0 {
                    Text(Self.formatDuration(video.duration))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 2)
                        .padding(.leading, 7)
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// "M:SS" / "H:MM:SS" from a seconds count.
    static func formatDuration(_ secs: Int) -> String {
        let h = secs / 3600
        let m = (secs % 3600) / 60
        let s = secs % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    @ViewBuilder
    private func libraryCell(_ scene: BingeScene) -> some View {
        // NavigationLink(value:) pushes a timeline reel onto
        // whichever NavigationStack we're inside — the inner
        // `profilePath` when this profile is shown as a cover,
        // or the outer tab path when pushed. Either way the
        // user gets the native slide-from-right transition
        // plus interactive edge-pop, no fullScreenCover bounce.
        NavigationLink(
            value: BingeRoute.reel(
                .timeline(
                    scenes: shuffledQueue(
                        from: vm?.scenes ?? [scene],
                        pinning: scene.id
                    ),
                    startId: scene.id
                )
            )
        ) {
            ZStack {
                Color(white: 0.08)
                if let url = scene.screenshotURL(base: baseURL) {
                    AuthImageView(
                        url: url,
                        apiKey: apiKey,
                        contentMode: .fill,
                        maxPixel: 512
                    )
                }
            }
            // Width comes from the scroll container's relative
            // frame; aspectRatio gives the 9:16 portrait shape;
            // clipped + clipShape crop the .fill overflow + round
            // the corners.
            .containerRelativeFrame(
                .horizontal,
                count: 2,
                span: 1,
                spacing: 4
            )
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // Persistent corner badge (TikTok-style) for the stat that
            // matches the active sort. allowsHitTesting(false) so it
            // never steals the tile's navigation tap.
            .overlay(alignment: .bottomLeading) {
                sortStatBadge(for: scene)
                    .allowsHitTesting(false)
            }
            // Without contentShape, NavigationLink's tap target
            // collapses to the painted image's bounds — the
            // ZStack's `Color(white: 0.08)` fill behind the
            // image isn't treated as hit-testable. Result: the
            // left column of cells (which often hasn't loaded
            // its image yet by the time the user reaches them)
            // can't be tapped. Elevating the rounded-rect to
            // the contentShape pins the tap target to the
            // tile's frame.
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// Per-tile stat badge for the active sort. Renders nothing when
    /// the relevant value is missing (unrated / no views / no date).
    /// Badge glyph source — SF Symbol or a vector asset-catalog image
    /// (the views eye uses the same SVG as the web plugin).
    private enum BadgeIcon {
        case symbol(String)
        case asset(String)
    }

    @ViewBuilder
    private func sortStatBadge(for scene: BingeScene) -> some View {
        if let badge = sortStat(for: scene) {
            HStack(spacing: 3) {
                badgeGlyph(badge.icon)
                    // o_counter reads as a "like" — pink heart to match.
                    .foregroundStyle(badge.like ? Color.bingeLike : .white)
                Text(badge.text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: .black.opacity(0.7), radius: 2)
            .padding(.leading, 7)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func badgeGlyph(_ icon: BadgeIcon) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 9, weight: .bold))
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
        }
    }

    /// Resolve (glyph, label, isLike) for the active sort's stat.
    private func sortStat(
        for scene: BingeScene
    ) -> (icon: BadgeIcon, text: String, like: Bool)? {
        switch vm?.sort ?? .recent {
        case .views:
            guard let v = scene.playCount, v > 0 else { return nil }
            return (.asset("ViewIcon"), Self.compactCount(v), false)
        case .orgasms:
            guard let o = scene.oCounter, o > 0 else { return nil }
            return (.symbol("heart.fill"), Self.compactCount(o), true)
        case .rating:
            guard let r = scene.rating100 else { return nil }
            return (.symbol("star.fill"), formatRating(r), false)
        case .added:
            guard let t = Self.compactMonthYear(scene.createdAt)
            else { return nil }
            return (.symbol("calendar"), t, false)
        case .recent:
            guard let t = Self.compactMonthYear(
                Story.effectiveAt(for: scene)
            ) else { return nil }
            return (.symbol("calendar"), t, false)
        }
    }

    /// k/M-abbreviated count: 999 → "999", 23_400_000 → "23.4M".
    static func compactCount(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 10_000 {
            return String(format: "%.1f", Double(n) / 1000)
                .replacingOccurrences(of: ".0", with: "") + "k"
        }
        if n < 1_000_000 {
            return "\(Int((Double(n) / 1000).rounded()))k"
        }
        if n < 10_000_000 {
            return String(format: "%.1f", Double(n) / 1_000_000)
                .replacingOccurrences(of: ".0", with: "") + "M"
        }
        return "\(Int((Double(n) / 1_000_000).rounded()))M"
    }

    /// "Jun 2026" from a "YYYY-MM-DD" or ISO string; falls back to the
    /// bare year, then nil when unparseable/empty.
    static func compactMonthYear(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.prefix(7).split(separator: "-")
        guard parts.count == 2,
              let m = Int(parts[1]), (1...12).contains(m) else {
            let y = String(raw.prefix(4))
            return y.count == 4 ? y : nil
        }
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]
        return "\(months[m - 1]) \(parts[0])"
    }

    /// StashDB tile — cover image with a pink "STASHDB" badge,
    /// taps open the stashbox URL in Safari since we have no
    /// local stream to play.
    @ViewBuilder
    private func stashDBCell(_ scene: StashDBScene) -> some View {
        let url = URL(string: "https://stashdb.org/scenes/\(scene.id)")
        Link(destination: url ?? URL(string: "https://stashdb.org")!) {
            ZStack(alignment: .topLeading) {
                Color(white: 0.08)
                if let cover = scene.coverUrl,
                    let coverUrl = URL(string: cover)
                {
                    // StashDB-hosted public CDN — pass empty apiKey
                    // so AuthImageView skips the ApiKey header.
                    AuthImageView(
                        url: coverUrl,
                        apiKey: "",
                        contentMode: .fill,
                        maxPixel: 512
                    )
                }
                Text("STASHDB")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(Color.bingeLike.opacity(0.85))
                    )
                    .padding(6)
            }
            .containerRelativeFrame(
                .horizontal,
                count: 2,
                span: 1,
                spacing: 4
            )
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Photos placeholder

    @ViewBuilder
    private var photosPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 32))
                .foregroundStyle(.white.opacity(0.3))
            Text("Photos coming soon")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Error

    @ViewBuilder
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 6) {
            Text("Couldn't load profile")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 80)
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        let trimmed = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return "\(trimmed)\(path)"
    }

    /// Build the reel queue: tapped scene first, the rest shuffled.
    private func shuffledQueue(
        from all: [BingeScene],
        pinning id: String
    ) -> [BingeScene] {
        guard let pinned = all.first(where: { $0.id == id }) else {
            return all
        }
        let others = all.filter { $0.id != id }.shuffled()
        return [pinned] + others
    }
}

// Simple flow-wrap for the link chips. SwiftUI doesn't ship a
// built-in wrap layout; this uses iOS 16+'s Layout protocol so
// chips wrap to the next line when they overflow the available
// width — same shape as web's `flex-wrap`.
struct FlowChipRow: View {
    let chips: [(label: String, url: String)]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(chips, id: \.url) { chip in
                if let u = URL(string: chip.url) {
                    Link(destination: u) {
                        Text(chip.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                Capsule().stroke(
                                    Color.white.opacity(0.12),
                                    lineWidth: 1
                                )
                            )
                    }
                }
            }
        }
    }
}

// Tiny utility — splits an array into N-sized chunks. Used by the
// scenes grid to turn a flat scenes list into pairs (one HStack
// per pair). Not on Foundation; small enough to inline here.
extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

// Fullscreen PornHub player — streams the mp4 via binge-server's
// proxy (the source URL is time/IP-locked to the daemon's exit, so it
// can't play in the client directly). Mirrors the web's PornhubPlayer
// overlay: video + title + an "Open on PornHub" link + a Save-to-Stash
// action that hands the daemon the watch page to download.
struct PornhubPlayerSheet: View {
    let video: BingeServerService.PornhubVideo
    let performerStashId: String

    @Environment(\.dismiss) private var dismiss
    // Mute functionality removed for now — playback is always unmuted.
    private let muted = false
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var saveState: SaveState = .idle

    enum SaveState: Equatable {
        case idle, saving, saved, failed(String)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayerView(player: player).ignoresSafeArea()
            }
            if loading { BingeLoading() }
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                Spacer()
                footer
            }
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = video.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
            }
            HStack(spacing: 8) {
                if let url = URL(string: video.sourceUrl) {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Text("Open on PornHub")
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.bingeLike.opacity(0.5))
                        )
                        .overlay(
                            Capsule().stroke(
                                Color.bingeLike.opacity(0.7), lineWidth: 1
                            )
                        )
                    }
                }
                saveButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var saveButton: some View {
        switch saveState {
        case .saved:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Saved").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        case .failed(let msg):
            Button { Task { await save() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Retry").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.red.opacity(0.45)))
            }
            .help(msg)
        default:
            Button { Task { await save() } } label: {
                HStack(spacing: 5) {
                    if saveState == .saving {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(saveState == .saving ? "Saving…" : "Save to Stash")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
            }
            .disabled(saveState == .saving)
        }
    }

    private func save() async {
        saveState = .saving
        let req = BingeServerService.SaveToStashRequest(
            performerStashId: performerStashId,
            source: .pornhub,
            handle: nil,
            id: video.id,
            mediaUrl: video.sourceUrl,
            kind: "video",
            sourceUrl: video.sourceUrl,
            text: video.title,
            createdUtc: video.createdUtc
        )
        switch await BingeServerService.saveToStash(req) {
        case .ok: saveState = .saved
        case .failure(let msg): saveState = .failed(msg)
        }
    }

    private func start() {
        guard let url = URL(
            string: BingeServerService.pornhubStreamUrl(video.id)
        ) else { return }
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        player = p
        // Clear the spinner once the first frame is ready.
        Task { @MainActor in
            for _ in 0..<200 {  // ~20s ceiling
                if p.currentItem?.status == .readyToPlay {
                    loading = false
                    break
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            loading = false
        }
        p.play()
    }

    private func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowH: CGFloat = 0
        var maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 {
                x = 0
                y += rowH + spacing
                rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: maxX, height: y + rowH)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x - bounds.minX + s.width > maxW && x > bounds.minX {
                x = bounds.minX
                y += rowH + spacing
                rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
