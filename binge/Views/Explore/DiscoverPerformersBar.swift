import SwiftUI

// Horizontal scroll row of trending StashDB performers — mirrors
// the web's DiscoverPerformersBar (src/tabs/DiscoverPerformersBar.tsx).
// Mounted at the top of Explore.
//
// Each bubble:
//   - tap → opens the local profile if the performer is in the
//     user's library (their stash_id appears in
//     `fetchLinkedPerformers`), otherwise opens the read-only
//     StashDB-only profile (which carries the Follow CTA).
//   - in-library performers get a subtle pink ring around the
//     avatar so the user can scan which ones they already follow.
//
// Failure modes (no StashBox configured, network down, etc.) are
// silent — the row just renders nothing rather than surfacing an
// error. Same degradation strategy as DiscoveryFeedCard.
@MainActor
struct DiscoverPerformersBar: View {
    let onOpenLocal: (String) -> Void
    let onOpenStashDB: (StashDBTrendingPerformer) -> Void

    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    private var apiKey: String { KeychainStore.shared.stashApiKey }
    // Bound to the same UserDefaults key AllowedGendersStore reads.
    // We don't need the parsed Set here — only a String to drive
    // the reload-on-change via .onChange below.
    @AppStorage(AllowedGendersStore.storageKey)
    private var allowedGendersRaw: String = ""

    @State private var vm: DiscoverPerformersBarViewModel?

    var body: some View {
        // Always render the container so `.task` reliably fires
        // (Group wrapping an EmptyView can be elided by SwiftUI
        // before any modifiers attached to the group take effect).
        // Hidden via `.frame(height: 0)` when there's nothing to
        // show, so a configured-but-failed fetch silently collapses.
        VStack(alignment: .leading, spacing: 0) {
            if let vm, vm.shouldRender {
                content(vm)
            } else if let vm, !vm.loaded {
                // Skeleton while the trending performers fetch is
                // in flight on first appear. A row of muted gray
                // circles so the layout doesn't pop in.
                skeletonRow
            }
        }
        .task {
            if vm == nil {
                vm = DiscoverPerformersBarViewModel(
                    baseURL: baseURL, apiKey: apiKey
                )
            }
            await vm?.load()
        }
        .onChange(of: allowedGendersRaw) { _, _ in
            // Allowed-genders changed in Settings — re-fetch from
            // StashDB so the row reflects the new selection.
            Task { await vm?.reload() }
        }
    }

    /// Placeholder row of empty bubbles, sized to match the
    /// real content. Shown until the StashDB fetch returns;
    /// drops to a zero-height empty state when the fetch
    /// failed (no stashbox / no network).
    @ViewBuilder
    private var skeletonRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISCOVER PERFORMERS")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(0..<8, id: \.self) { _ in
                        VStack(spacing: 6) {
                            Circle()
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 64, height: 64)
                            Color.clear.frame(width: 60, height: 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    @ViewBuilder
    private func content(
        _ vm: DiscoverPerformersBarViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISCOVER PERFORMERS")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 16)
                .padding(.top, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(vm.performers) { perf in
                        bubble(
                            perf,
                            linkedLocalId: vm.linkedIdToLocal[perf.id]
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func bubble(
        _ perf: StashDBTrendingPerformer,
        linkedLocalId: String?
    ) -> some View {
        let linked = linkedLocalId != nil
        Button {
            if let localId = linkedLocalId {
                onOpenLocal(localId)
            } else {
                onOpenStashDB(perf)
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(Color.gray.opacity(0.3))
                    if let imgStr = perf.image,
                        let url = URL(string: imgStr)
                    {
                        AuthImageView(
                            url: url,
                            apiKey: "",
                            contentMode: .fill,
                            maxPixel: 256,
                            alignment: .top
                        )
                    } else {
                        Text(String(perf.name.prefix(1)))
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        linked
                            ? Color.bingeVerified
                            : Color.white.opacity(0.12),
                        lineWidth: linked ? 2.5 : 1
                    )
                )
                Text(perf.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View model

/// Loads two pieces of data in parallel on appear:
///   - trending performers from stashdb.org (via queryPerformers)
///   - linked performers from Stash (for the in-library ring)
///
/// Caches both in memory — the trending list barely moves
/// day-to-day, so one fetch per app launch is fine. Pull-to-
/// refresh on Explore re-runs the inner ExploreViewModel.load(),
/// not this; if we want to refresh trending too we'd plumb that
/// later.
@Observable
@MainActor
final class DiscoverPerformersBarViewModel {
    var performers: [StashDBTrendingPerformer] = []
    /// stash_id → localId for the bubble that already lives in
    /// the user's library. The "linked" ring is keyed on
    /// linkedIds.contains so the in-library check is a hash hit.
    var linkedIds: Set<String> = []
    var linkedIdToLocal: [String: String] = [:]
    var loaded: Bool = false
    var loading: Bool = false

    private let baseURL: String
    private let apiKey: String

    /// True when there's something worth rendering. Hides the
    /// row entirely when the fetch failed (no stashbox / network
    /// down) so the Explore header doesn't carry an empty band.
    var shouldRender: Bool {
        loaded && !performers.isEmpty
    }

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func load() async {
        if loading || loaded { return }
        await runFetch()
    }

    /// Force a fresh fetch (drops the `loaded` short-circuit) —
    /// used when the user's allowed-genders selection changes in
    /// Settings.
    func reload() async {
        if loading { return }
        loaded = false
        await runFetch()
    }

    private func runFetch() async {
        loading = true
        defer { loading = false }
        let svc = StashDBService(baseURL: baseURL, apiKey: apiKey)
        guard let box = await svc.cachedBoxConfig() else {
            print("[binge] discover bar: no stashbox configured")
            loaded = true  // mark loaded so we don't retry on every tab return
            return
        }
        let genders = Array(AllowedGendersStore.visibleStrings())
        async let trendingTask = svc.cachedTrendingPerformers(
            apiKey: box.apiKey, perPage: 30, genders: genders
        )
        async let linkedTask = svc.cachedLinkedPerformers()
        let (trending, linked) = await (trendingTask, linkedTask)
        print(
            "[binge] discover bar: trending=\(trending.count) "
                + "linked=\(linked.count)"
        )
        performers = trending
        linkedIdToLocal = Dictionary(
            linked.map { ($0.stashId, $0.localId) },
            // Two locals could be linked to the same stash_id
            // (duplicate-import data quirk); keep whichever we
            // see first.
            uniquingKeysWith: { first, _ in first }
        )
        linkedIds = Set(linkedIdToLocal.keys)
        loaded = true
    }
}
