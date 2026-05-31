import SwiftUI

// "Following" tab — every performer in the user's Stash library
// split into a Favourites section and an All section, both
// filterable by a single search box. Tap any card → opens that
// performer's profile.
//
// Mirrors src/tabs/Following.tsx without (yet) the 6-mode sort
// dropdown; for v0.2 we lean on the query's name-ASC ordering and
// the substring search.
struct FollowingView: View {
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

    @State private var vm: FollowingViewModel?
    @State private var tour = TourDirector.shared
    /// Drilled-in destinations pushed onto Following's
    /// NavigationStack. Today: `.performer(localId:)` only —
    /// tile tap pushes the profile via the shared
    /// `bingeRouteDestinations()` modifier, which mounts
    /// PerformerProfileSheet without its internal NavigationStack
    /// so chrome lives on the outer one.
    @State private var path: [BingeRoute] = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let vm {
                        searchBar(vm: vm)
                        switch vm.loadState {
                        case .idle, .loading:
                            if vm.all.isEmpty {
                                ProgressView()
                                    .tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 60)
                            } else {
                                sections(vm: vm)
                            }
                        case .loaded:
                            sections(vm: vm)
                        case .error(let msg):
                            errorView(msg)
                        }
                    } else {
                        ProgressView()
                            .tint(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    }
                }
            }
            .background(Color.black.ignoresSafeArea())
            .statusBarHidden(tour.isRunning)
            // Drag-down to dismiss the search keyboard — feels
            // natural and avoids needing an explicit "Done" button.
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await vm?.load()
            }
            .navigationTitle("Following")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BingeLogoMark()
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .bingeRouteDestinations()
        }
        .task {
            if vm == nil {
                vm = FollowingViewModel(
                    baseURL: stashUrl,
                    apiKey: stashApiKey
                )
            }
            if vm?.all.isEmpty == true {
                await vm?.load()
            }
        }
        // Walkthrough: open a performer's profile.
        .onChange(of: tour.tick) { _, _ in
            guard case .followingOpenPerformer(let i) = tour.command,
                let vm
            else { return }
            let list = vm.all
            guard !list.isEmpty else { return }
            let p = list.indices.contains(i) ? list[i] : list[0]
            path.append(.performer(localId: p.id))
        }
    }

    // MARK: - Search + sort row

    @ViewBuilder
    private func searchBar(vm: FollowingViewModel) -> some View {
        HStack(spacing: 8) {
            searchField(vm: vm)
            sortMenu(vm: vm)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func searchField(vm: FollowingViewModel) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            TextField(
                "",
                text: Binding(
                    get: { vm.search },
                    set: { vm.search = $0 }
                ),
                prompt: Text("Search performers")
                    .foregroundStyle(.white.opacity(0.45))
            )
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .focused($searchFocused)
            .submitLabel(.search)
            if !vm.search.isEmpty || searchFocused {
                Button {
                    vm.search = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.08))
        )
    }

    // Compact sort dropdown — Menu with the current sort label as
    // the trigger. Mirrors the web's <select> dropdown. Tap →
    // system-native popover of options.
    @ViewBuilder
    private func sortMenu(vm: FollowingViewModel) -> some View {
        Menu {
            Picker(
                "Sort",
                selection: Binding(
                    get: { vm.sort },
                    set: { vm.sort = $0 }
                )
            ) {
                ForEach(FollowingSortMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }

    // MARK: - Sections + grid

    @ViewBuilder
    private func sections(vm: FollowingViewModel) -> some View {
        let split = vm.sections
        section(
            title: "Favourites",
            count: split.favourites.count,
            performers: split.favourites,
            emptyHint: vm.all.contains(where: { $0.isFavourite })
                ? "No matches."
                : "Favourite some performers to see them here.",
            isFavourite: true
        )
        section(
            title: "All performers",
            count: split.others.count,
            performers: split.others,
            emptyHint: "No matches.",
            isFavourite: false
        )
    }

    @ViewBuilder
    private func section(
        title: String,
        count: Int,
        performers: [PerformerSummary],
        emptyHint: String,
        isFavourite: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            .padding(.horizontal, 16)

            if performers.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
            } else {
                grid(performers: performers)
            }
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private func grid(performers: [PerformerSummary]) -> some View {
        // LazyVGrid distributes column widths automatically — no
        // need to read screen width (UIScreen.main is deprecated
        // in iOS 26). The cards drop their explicit-width frames
        // and rely on the grid's flexible columns for layout.
        let interCell: CGFloat = 8
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: interCell),
            count: 3
        )
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(performers, id: \.id) { performer in
                card(performer)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func card(_ p: PerformerSummary) -> some View {
        // Inlined the avatar build + dropped the Button wrapper.
        // SwiftUI's Button label sizing can swallow explicit-frame
        // requests in some nested-layout cases; a plain VStack
        // with an onTapGesture lays out deterministically.
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(Color.white.opacity(0.08))
                if let path = p.imagePath,
                   let url = URL(string: absolute(path)) {
                    AuthImageView(
                        url: url,
                        apiKey: stashApiKey,
                        contentMode: .fill,
                        maxPixel: 256,
                        alignment: .top
                    )
                    .clipShape(Circle())
                } else {
                    Text(String(p.name.prefix(1)))
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            // Avatar is a 1:1 Circle that fills the cell's width
            // minus a hair of inset — sized by the column instead
            // of an explicit width.
            .aspectRatio(1, contentMode: .fit)
            .padding(.horizontal, 2)
            .overlay(
                Circle().stroke(
                    p.isFavourite
                        ? Color.bingeLike.opacity(0.55)
                        : Color.white.opacity(0.08),
                    lineWidth: p.isFavourite ? 1.5 : 1
                )
                .padding(.horizontal, 2)
            )

            Text(p.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(sceneCountLabel(p.sceneCount))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            path.append(.performer(localId: p.id))
        }
    }

    /// Empty string keeps the Text in the layout (reserves height)
    /// without visually rendering anything.
    private func sceneCountLabel(_ n: Int?) -> String {
        guard let n, n > 0 else { return " " }
        return "\(n) scene\(n == 1 ? "" : "s")"
    }

    // MARK: - Error

    @ViewBuilder
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 6) {
            Text("Couldn't load performers")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        let trimmed = stashUrl.trimmingCharacters(in: .init(charactersIn: "/"))
        return "\(trimmed)\(path)"
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
