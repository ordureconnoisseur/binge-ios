import SwiftUI

// Read-only profile for a StashDB performer the user hasn't added
// to their library yet. Mirrors PerformerProfileSheet visually
// (same hero / bio / scenes-grid skeleton) but every read comes
// from stashdb.org rather than Stash, and write actions (favourite,
// rating) are absent.
//
// Phase B of the StashDB integration — Phase C will graft a
// "Follow" button onto the header that scrapes + creates the
// performer locally, after which the user is bounced into the
// regular PerformerProfileSheet for the new local id.
//
// Discovery: reached from a DiscoveryFeedCard performer tap when
// the performer has no localId, and (Phase D) from a tap on a
// DiscoverPerformersBar bubble when the trending performer isn't
// linked.
@MainActor
struct StashDBPerformerProfile: View {
    let stashId: String
    /// Fallback values used until the GraphQL fetch lands —
    /// lets the header render the name + avatar from the
    /// discovery card's payload immediately rather than showing
    /// a "loading…" spinner. nil for entry points (Phase D
    /// bubble tap) that don't have these on hand.
    let fallbackName: String?
    let fallbackImage: String?

    @Environment(\.dismiss) private var dismiss
    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    private var apiKey: String { KeychainStore.shared.stashApiKey }

    @State private var vm: StashDBPerformerProfileViewModel?
    /// Set after a successful Follow → triggers the cover-swap to
    /// the regular library profile sheet using the new local id.
    @State private var followedLocalId: String?

    init(
        stashId: String,
        fallbackName: String? = nil,
        fallbackImage: String? = nil
    ) {
        self.stashId = stashId
        self.fallbackName = fallbackName
        self.fallbackImage = fallbackImage
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let vm {
                        // Header always renders — uses fallback
                        // name/image while the GraphQL fetch is in
                        // flight so we don't flash a spinner over
                        // the whole sheet.
                        heroRow(vm)
                        bio(vm)
                        followButton(vm)
                        if vm.loading && vm.detail == nil {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 30)
                        }
                        if vm.error != nil && vm.detail == nil {
                            inlineError
                        }
                        scenesSection(vm)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle(vm?.detail?.name ?? fallbackName ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(
                        destination: URL(
                            string: "https://stashdb.org/performers/\(stashId)"
                        )!
                    ) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .swipeRightToDismiss()
        .task {
            if vm == nil {
                vm = StashDBPerformerProfileViewModel(
                    stashId: stashId,
                    fallbackName: fallbackName,
                    fallbackImage: fallbackImage,
                    baseURL: baseURL,
                    apiKey: apiKey
                )
            }
            await vm?.load()
        }
        // Followed → swap this sheet for the regular library
        // profile (same fullScreenCover lane, different content).
        .fullScreenCover(
            isPresented: Binding(
                get: { followedLocalId != nil },
                set: { if !$0 { followedLocalId = nil } }
            )
        ) {
            if let id = followedLocalId {
                PerformerProfileSheet(performerId: id)
            }
        }
    }

    // MARK: - Hero row

    @ViewBuilder
    private func heroRow(
        _ vm: StashDBPerformerProfileViewModel
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            avatar(vm)
            statsRow(vm)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func avatar(
        _ vm: StashDBPerformerProfileViewModel
    ) -> some View {
        let size: CGFloat = 96
        let imgStr = vm.detail?.images.first ?? fallbackImage
        ZStack {
            Color.gray.opacity(0.3)
            if let s = imgStr, let url = URL(string: s) {
                AuthImageView(
                    url: url,
                    apiKey: "",
                    contentMode: .fill,
                    maxPixel: 256,
                    alignment: .top
                )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func statsRow(
        _ vm: StashDBPerformerProfileViewModel
    ) -> some View {
        // Stats mirror the web's StashDB profile —
        // scenes / in library / aliases. StashDB doesn't expose
        // an o-counter or galleries (those are local-only Stash
        // concepts), so those slots get repurposed to lean into
        // what the StashDB record DOES tell you.
        HStack(spacing: 0) {
            stat(
                label: "SCENES",
                value: vm.detail.map { compact(Int64($0.sceneCount)) }
                    ?? "—"
            )
            divider
            stat(
                label: "IN LIBRARY",
                value: vm.detail == nil
                    ? "—"
                    : compact(Int64(vm.ownedSceneCount))
            )
            divider
            stat(
                label: "ALIASES",
                value: vm.detail.map {
                    compact(Int64($0.aliases.count))
                } ?? "—"
            )
        }
    }

    @ViewBuilder
    private func stat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1, height: 28)
    }

    private func compact(_ n: Int64) -> String {
        if n >= 1000 {
            let v = Double(n) / 1000
            return v >= 10
                ? "\(Int(v.rounded()))K"
                : String(format: "%.1fK", v)
        }
        return String(n)
    }

    // MARK: - Bio

    @ViewBuilder
    private func bio(
        _ vm: StashDBPerformerProfileViewModel
    ) -> some View {
        let name = vm.detail?.name ?? fallbackName ?? ""
        VStack(alignment: .leading, spacing: 6) {
            Text(name)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            if let d = vm.detail, !d.aliases.isEmpty {
                Text("a.k.a. \(d.aliases.joined(separator: ", "))")
                    .font(.system(size: 13).italic())
                    .foregroundStyle(.white.opacity(0.6))
            }
            if let d = vm.detail {
                let attrs = attributeLine(d)
                if !attrs.isEmpty {
                    Text(attrs)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.78))
                }
                if !d.urls.isEmpty {
                    PerformerLinks(urls: d.urls.map(\.url))
                        .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    /// "US · 1992 · blonde · hazel eyes · female · 178 cm · 32B-24-34"
    /// — bio summary. Mirrors the web BioAttrs join order: country,
    /// birth year, hair, eyes, gender, height, measurements.
    /// Lowercases hair/eyes/gender to match the IG-ish aesthetic
    /// the web uses (capitalized words on profile pages look
    /// like form labels rather than bio text).
    private func attributeLine(_ d: StashDBPerformerDetail) -> String {
        var parts: [String] = []
        if let c = d.country, !c.isEmpty { parts.append(c) }
        if let bd = d.birthDate,
            let year = bd.split(separator: "-").first
        {
            parts.append(String(year))
        }
        if let hair = d.hairColor, !hair.isEmpty {
            parts.append(hair.lowercased())
        }
        if let eyes = d.eyeColor, !eyes.isEmpty {
            parts.append("\(eyes.lowercased()) eyes")
        }
        if let g = d.gender, !g.isEmpty {
            parts.append(genderLabel(g))
        }
        if let h = d.height { parts.append("\(h) cm") }
        if let m = d.measurements, !m.isEmpty {
            parts.append(m)
        }
        return parts.joined(separator: " · ")
    }

    /// Mirrors web's genderLabel — humanizes StashDB's enum
    /// values for inline display ("TRANSGENDER_FEMALE" →
    /// "trans female"). Unknown values fall through lowercased.
    private func genderLabel(_ g: String) -> String {
        switch g {
        case "FEMALE": return "female"
        case "TRANSGENDER_FEMALE": return "trans female"
        case "MALE": return "male"
        case "TRANSGENDER_MALE": return "trans male"
        case "INTERSEX": return "intersex"
        case "NON_BINARY": return "non-binary"
        default: return g.lowercased()
        }
    }

    // MARK: - Follow button

    /// Pink CTA that scrapes + creates the performer locally.
    /// While in flight: "Following…" with the button disabled.
    /// On success: dismiss this sheet and re-route to the library
    /// profile via the `followedLocalId` cover. On failure: stays
    /// put and shows the error inline below the button.
    @ViewBuilder
    private func followButton(
        _ vm: StashDBPerformerProfileViewModel
    ) -> some View {
        VStack(spacing: 6) {
            Button {
                guard !vm.following else { return }
                Task {
                    if let localId = await vm.follow() {
                        followedLocalId = localId
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if vm.following {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    Text(vm.following ? "Following…" : "Follow")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.bingeLike.opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.bingeLike, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(vm.following)
            if let err = vm.followError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
    }

    // MARK: - Scenes section

    @ViewBuilder
    private func scenesSection(
        _ vm: StashDBPerformerProfileViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SCENES (\(vm.scenes.count))")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 22)
                .padding(.top, 14)
            if vm.scenes.isEmpty && vm.loadingScenes {
                ProgressView()
                    .tint(.white)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if vm.scenes.isEmpty {
                Text("No scenes on StashDB")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                sceneGrid(vm.scenes, owned: vm.ownedSceneIds)
                    .padding(.bottom, 30)
            }
        }
    }

    @ViewBuilder
    private func sceneGrid(
        _ scenes: [StashDBScene], owned: Set<String>
    ) -> some View {
        let rows = scenes.chunked(into: 2)
        LazyVStack(spacing: 4) {
            ForEach(rows.indices, id: \.self) { idx in
                let row = rows[idx]
                HStack(spacing: 4) {
                    ForEach(row, id: \.id) { scene in
                        stashDBCell(
                            scene, isOwned: owned.contains(scene.id)
                        )
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
            }
        }
    }

    @ViewBuilder
    private func stashDBCell(
        _ scene: StashDBScene, isOwned: Bool
    ) -> some View {
        let url = URL(string: "https://stashdb.org/scenes/\(scene.id)")
        Link(destination: url ?? URL(string: "https://stashdb.org")!) {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .bottomLeading) {
                    Color(white: 0.08)
                    if let cover = scene.coverUrl,
                        let coverUrl = URL(string: cover)
                    {
                        AuthImageView(
                            url: coverUrl,
                            apiKey: "",
                            contentMode: .fill,
                            maxPixel: 512
                        )
                    }
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0),
                            Color.black.opacity(0.7),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        if let title = scene.title, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                        }
                        if let date = scene.releaseDate {
                            Text(String(date.prefix(10)))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(8)
                }
                // Per-tile badge — pink "STASHDB" for unowned,
                // green "IN LIBRARY" for owned. Mirrors web's
                // .binge-profile-scene-stashdb-badge.is-owned
                // pattern so the two surfaces feel consistent.
                Text(isOwned ? "IN LIBRARY" : "STASHDB")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(
                            isOwned
                                ? Color.bingeVerified.opacity(0.85)
                                : Color.bingeLike.opacity(0.85)
                        )
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

    // MARK: - Error

    @ViewBuilder
    private var inlineError: some View {
        VStack(spacing: 6) {
            Text("Couldn't load StashDB profile")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(
                "StashDB may be down, or this performer's id "
                    + "isn't reachable. The performer's scenes "
                    + "will still try to load below."
            )
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }
}

// MARK: - View model

/// Loads detail + scenes for a StashDB performer. Two parallel
/// fetches kicked off on appear; one stays loaded while the other
/// is in flight (so the header can render from `detail` while
/// the grid renders from `scenes`).
@Observable
@MainActor
final class StashDBPerformerProfileViewModel {
    var detail: StashDBPerformerDetail?
    /// Every StashDB scene tied to this performer, INCLUDING the
    /// ones the user already owns locally — matches the web's
    /// profile behavior. Owned scenes get an "In library" badge
    /// instead of the "StashDB" badge so they're distinguishable
    /// at a glance.
    var scenes: [StashDBScene] = []
    /// stash_ids the user already has imported locally. Used by
    /// the "in library" stat + per-tile badge.
    var ownedSceneIds: Set<String> = []
    var loading: Bool = false
    var loadingScenes: Bool = false
    var error: String?
    /// In-flight flag for the Follow flow — disables the button
    /// and swaps its label to "Following…". Cleared at the end of
    /// `follow()` regardless of success/failure.
    var following: Bool = false
    /// User-visible error message from the last follow attempt.
    /// nil clears the inline error from under the button.
    var followError: String?
    /// Cached stashBoxIndex from fetchBoxConfig — avoids re-
    /// querying box config when the user taps Follow. Set during
    /// load().
    private var stashBoxIndex: Int = 0

    let stashId: String
    let fallbackName: String?
    let fallbackImage: String?
    private let baseURL: String
    private let apiKey: String

    init(
        stashId: String,
        fallbackName: String?,
        fallbackImage: String?,
        baseURL: String,
        apiKey: String
    ) {
        self.stashId = stashId
        self.fallbackName = fallbackName
        self.fallbackImage = fallbackImage
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func load() async {
        if loading || detail != nil { return }
        loading = true
        loadingScenes = true
        defer {
            loading = false
            loadingScenes = false
        }
        let svc = StashDBService(baseURL: baseURL, apiKey: apiKey)
        guard let box = await svc.cachedBoxConfig() else {
            error = "StashDB not configured in Stash"
            return
        }
        stashBoxIndex = box.index
        async let detailTask = svc.cachedPerformerDetail(
            stashId: stashId, apiKey: box.apiKey
        )
        async let scenesTask = svc.cachedScenesForStashDBPerformer(
            stashId: stashId, apiKey: box.apiKey
        )
        async let ownedTask = svc.cachedOwnedStashIds()
        let (d, raw, owned) = await (detailTask, scenesTask, ownedTask)
        detail = d
        scenes = raw
        // An unknown ownership answer keeps whatever was already known
        // rather than claiming the user owns none of these - the "in
        // library" stat and the Add affordance both read this, and Add
        // creates a second row carrying a stash_id the library already
        // uses.
        if let owned { ownedSceneIds = owned }
        if d == nil {
            error = "Couldn't load profile"
        }
    }

    /// Number of this performer's StashDB scenes the user has
    /// already imported into their local library. Drives the "in
    /// library" stat.
    var ownedSceneCount: Int {
        scenes.reduce(0) {
            ownedSceneIds.contains($1.id) ? $0 + 1 : $0
        }
    }

    /// Scrape + create the performer locally. Returns the new
    /// localId on success, nil otherwise (the error message is
    /// surfaced via `followError`).
    ///
    /// Idempotency: before scraping we check the existing linked
    /// performers list — if the user already has a local
    /// performer carrying this stash_id, we return that id
    /// directly. Mobile fat-finger guard.
    func follow() async -> String? {
        if following { return nil }
        following = true
        followError = nil
        defer { following = false }
        let svc = StashDBService(baseURL: baseURL, apiKey: apiKey)
        // Fails closed. This lookup is the only thing standing between
        // Follow and a duplicate performer in the user's library, and
        // the fetch now reports a failure as nil rather than as an empty
        // list - so a Stash blip must stop the Follow rather than let it
        // conclude nobody is linked and create a second copy.
        guard let linked = await svc.fetchLinkedPerformers() else {
            followError =
                "Could not check your library just now, so nothing was "
                + "added. Try again in a moment."
            return nil
        }
        if let existing = linked.first(where: { $0.stashId == stashId }) {
            return existing.localId
        }
        let follow = FollowService(baseURL: baseURL, apiKey: apiKey)
        do {
            let result = try await follow.followStashDBPerformer(
                stashId: stashId,
                fallbackName: detail?.name ?? fallbackName ?? "Unknown",
                fallbackImage: detail?.images.first ?? fallbackImage,
                stashBoxIndex: stashBoxIndex
            )
            return result.id
        } catch {
            print("[binge] follow failed: \(error)")
            followError = "Couldn't add to library. Try again."
            return nil
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        precondition(size > 0)
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
