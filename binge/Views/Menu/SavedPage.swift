import SwiftUI

// IG-style Saved page. 2-column tile grid; each tile shows the
// latest scene's screenshot as cover + the collection name + a
// dedicated icon for the two defaults (Favourites / Watch Later)
// or a generic folder glyph for user-created ones. Long-press a
// non-default tile → delete confirmation. + in the toolbar →
// inline create input.
//
// Mirrors src/tabs/SavedPage.tsx. Per-collection scene browsing
// pushes to CollectionDetailPage on tap.
struct SavedPage: View {
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

    @State private var tour = TourDirector.shared
    @State private var service: CollectionsService?
    @State private var covers: [String: [String]] = [:]  // tagName → up to 4 URLs
    @State private var creating: Bool = false
    @State private var newName: String = ""
    @State private var busy: Bool = false
    @State private var confirmDelete: CollectionDef?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if creating {
                    createForm
                }
                content
            }
            .padding(.bottom, 30)
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden(tour.isRunning)
        .navigationTitle("Saved")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    creating.toggle()
                    if creating { nameFieldFocused = true }
                } label: {
                    Image(
                        systemName: creating ? "xmark" : "plus"
                    )
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                }
            }
        }
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        // Resolves the per-tile NavigationLink(value: coll) push.
        // The destination lives here (not on MenuPage) so it has
        // access to SavedPage's `service` — preserves the cached
        // tagIds so CollectionDetailPage doesn't have to re-resolve
        // them on every push.
        .navigationDestination(for: CollectionDef.self) { coll in
            CollectionDetailPage(
                collection: coll,
                service: service
            )
        }
        .task {
            if service == nil {
                service = CollectionsService(
                    baseURL: stashUrl,
                    apiKey: stashApiKey
                )
            }
            await service?.load()
            await loadCovers()
        }
        .confirmationDialog(
            confirmDeleteTitle,
            isPresented: Binding(
                get: { confirmDelete != nil },
                set: { if !$0 { confirmDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmDelete
        ) { coll in
            Button("Delete", role: .destructive) {
                Task { await handleDelete(coll) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { coll in
            Text(
                coll.isDefault
                    ? "Default collections can't be deleted."
                    : "This removes the collection from Stash. "
                        + "The scenes themselves aren't affected."
            )
        }
    }

    private var confirmDeleteTitle: String {
        confirmDelete.map { "Delete \"\($0.name)\"?" } ?? ""
    }

    // MARK: - Create form

    @ViewBuilder
    private var createForm: some View {
        HStack(spacing: 8) {
            TextField(
                "",
                text: $newName,
                prompt: Text("Collection name")
                    .foregroundStyle(.white.opacity(0.4))
            )
            .focused($nameFieldFocused)
            .font(.system(size: 14))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )
            .submitLabel(.done)
            .onSubmit { Task { await handleCreate() } }
            Button {
                Task { await handleCreate() }
            } label: {
                Text("Create")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.bingeLike.opacity(0.6))
                    )
            }
            .buttonStyle(.plain)
            .disabled(
                busy
                    || newName.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let service {
            switch service.loadState {
            case .idle:
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            case .loading:
                if service.collections.isEmpty {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    // Re-fetching after a mutation — show the
                    // previous list so the user doesn't see a
                    // blank screen.
                    grid(service: service)
                }
            case .loaded:
                grid(service: service)
            case .error(let msg):
                errorView(msg)
            }
        }
    }

    @ViewBuilder
    private func grid(service: CollectionsService) -> some View {
        // LazyVGrid distributes columns automatically — no need
        // for UIScreen.main (deprecated in iOS 26).
        let gap: CGFloat = 12
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: gap),
            count: 2
        )
        LazyVGrid(columns: columns, spacing: gap) {
            ForEach(service.collections, id: \.id) { coll in
                tile(coll: coll)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func tile(coll: CollectionDef) -> some View {
        // Value-based push (resolved by MenuPage's
        // .navigationDestination(for: CollectionDef.self)).
        // Mixing this with NavigationLink {destination} on the
        // same stack made tile taps inside CollectionDetailPage
        // double-push the collection on top of the pushed reel —
        // SwiftUI couldn't reconcile the inline destination with
        // the path-based child push. Keeping every push on the
        // path side is the working pattern.
        NavigationLink(value: coll) {
            VStack(alignment: .leading, spacing: 6) {
                cover(coll: coll)
                HStack(spacing: 6) {
                    Image(systemName: iconName(for: coll.icon))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(iconColor(for: coll.icon))
                    Text(coll.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer()
                }
            }
        }
        .buttonStyle(.plain)
        // Only on a collection that can actually be deleted. The
        // gesture was on every tile, so long-pressing Favourites or
        // Watch Later opened a dialog headed Delete "Favourites"? with
        // a red Delete button - which delete() then refused in
        // silence. A destructive button that does nothing is worse
        // than no button. maximumDistance is explicit for the same
        // reason HoldAndPull sets it: a finger resting on a tile
        // before a drag should not open a delete dialog mid-scroll.
        .onLongPressGesture(minimumDuration: 0.6, maximumDistance: 8) {
            guard !coll.isDefault else { return }
            confirmDelete = coll
        }
    }

    @ViewBuilder
    private func cover(coll: CollectionDef) -> some View {
        // Square 2×2 mosaic of the 4 newest scenes' screenshots.
        // Width comes from the LazyVGrid column; aspect-ratio
        // squares the tile. Inner cells use GeometryReader to
        // pick up the resolved width and split it.
        let urls = covers[coll.tagName] ?? []
        ZStack {
            Color(white: 0.06)
            GeometryReader { geo in
                let cellSize = (geo.size.width - 2) / 2
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        coverCell(url: urls[safe: 0], coll: coll, size: cellSize)
                        coverCell(url: urls[safe: 1], coll: coll, size: cellSize)
                    }
                    HStack(spacing: 2) {
                        coverCell(url: urls[safe: 2], coll: coll, size: cellSize)
                        coverCell(url: urls[safe: 3], coll: coll, size: cellSize)
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func coverCell(
        url: String?,
        coll: CollectionDef,
        size: CGFloat
    ) -> some View {
        ZStack {
            Color(white: 0.10)
            if let path = url, let u = URL(string: absolute(path)) {
                AuthImageView(
                    url: u,
                    apiKey: stashApiKey,
                    contentMode: .fill,
                    maxPixel: 400
                )
            } else {
                Image(systemName: iconName(for: coll.icon))
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    @ViewBuilder
    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 6) {
            Text("Couldn't load collections")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }

    // MARK: - Actions

    private func handleCreate() async {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        busy = true
        defer { busy = false }
        _ = await service?.create(name: name)
        newName = ""
        creating = false
        nameFieldFocused = false
        await loadCovers()
    }

    private func handleDelete(_ coll: CollectionDef) async {
        _ = await service?.delete(coll)
        covers.removeValue(forKey: coll.tagName)
    }

    private func loadCovers() async {
        guard let service else { return }
        for coll in service.collections {
            if covers[coll.tagName] != nil { continue }
            let urls = await service.covers(for: coll)
            covers[coll.tagName] = urls
        }
    }

    // MARK: - Helpers

    private func iconName(for icon: CollectionIcon) -> String {
        switch icon {
        case .favourite: return "heart.fill"
        case .watchLater: return "clock.fill"
        case .generic: return "folder.fill"
        }
    }

    private func iconColor(for icon: CollectionIcon) -> Color {
        switch icon {
        case .favourite: return Color.bingeLike
        case .watchLater: return Color.orange
        case .generic: return .white.opacity(0.7)
        }
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

    /// Safe subscript — returns nil if out of bounds. Used by the
    /// cover grid which needs to render even when a collection
    /// has fewer than 4 scenes.
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
