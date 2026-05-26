import SwiftUI

// Bottom sheet listing Stash's native saved scene filters. Tap a
// row to apply it; the reel re-fetches with the saved filter's
// object_filter + sort/direction. Mirrors src/filter/FilterSheet.tsx
// minus the build-your-own active-chips section (that's deferred).
struct ReelFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(FilterNavigator.self) private var nav
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

    @State private var loadState: LoadState = .idle
    @State private var filters: [StashSavedFilter] = []

    enum LoadState: Equatable {
        case idle
        case loading
        case ready
        case error(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    activeSection
                    Divider()
                        .background(Color.white.opacity(0.08))
                        .padding(.vertical, 4)
                    savedFiltersSection
                }
            }
            .background(Color(white: 0.07).ignoresSafeArea())
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(Color(white: 0.07), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            if filters.isEmpty {
                await load()
            }
        }
    }

    // MARK: - Active

    @ViewBuilder
    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ACTIVE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if nav.active != nil {
                    Button("Clear") {
                        nav.active = nil
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.bingeLike)
                }
            }
            if let active = nav.active {
                activeChip(active)
            } else {
                Text("No active filter — showing everything.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func activeChip(_ sf: StashSavedFilter) -> some View {
        Button {
            nav.active = nil
        } label: {
            HStack(spacing: 6) {
                Text(sf.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color.bingeLike.opacity(0.25))
            )
            .overlay(
                Capsule().stroke(
                    Color.bingeLike.opacity(0.5),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Saved filters list

    @ViewBuilder
    private var savedFiltersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("STASH SAVED FILTERS")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 18)
                .padding(.top, 10)
            switch loadState {
            case .idle, .loading:
                BingeLoading(compact: true)
                    .padding(.vertical, 24)
            case .ready:
                if filters.isEmpty {
                    Text(
                        "No saved filters for scenes. Create them in "
                            + "Stash's scene browser — they'll appear "
                            + "here automatically."
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(filters) { sf in
                            row(sf)
                            if sf.id != filters.last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.06))
                                    .padding(.leading, 18)
                            }
                        }
                    }
                }
            case .error(let msg):
                Text("Couldn't load: \(msg)")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            }
        }
        .padding(.bottom, 30)
    }

    @ViewBuilder
    private func row(_ sf: StashSavedFilter) -> some View {
        let active = nav.active?.id == sf.id
        Button {
            nav.active = sf
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(sf.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    if let summary = subtitle(sf), !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.bingeLike)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Compact summary of which criteria the saved filter touches +
    /// its sort. Helps the user pick the right filter at a glance.
    private func subtitle(_ sf: StashSavedFilter) -> String? {
        var parts: [String] = []
        if let dict = sf.objectFilter?.asObject {
            let keys = Array(dict.keys).sorted()
            if !keys.isEmpty {
                let shown = keys.prefix(4).joined(separator: " · ")
                if keys.count > 4 {
                    parts.append("\(shown) · +\(keys.count - 4)")
                } else {
                    parts.append(shown)
                }
            }
        }
        if let sort = sf.findFilter?.sort, !sort.isEmpty {
            parts.append("sort: \(sort)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Load

    private func load() async {
        loadState = .loading
        let client = StashClient(baseURL: stashUrl, apiKey: stashApiKey)
        do {
            let resp: FindSavedFiltersResponse = try await client.gql(
                Queries.findSavedFilters,
                variables: [:]
            )
            filters = resp.findSavedFilters
            loadState = .ready
        } catch {
            loadState = .error(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
        }
    }
}
