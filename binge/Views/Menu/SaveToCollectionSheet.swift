import SwiftUI

// "Save to..." sheet — opened from the reel's bookmark icon.
// Lists every collection with a check mark next to the ones this
// scene already belongs to; tap a row toggles membership. + row
// creates a new collection inline.
//
// Each toggle hits the Stash sceneUpdate mutation with the new
// tag_ids list. We optimistically flip the local memberships
// state and roll back if the mutation fails.
struct SaveToCollectionSheet: View {
    let scene: BingeScene

    @Environment(\.dismiss) private var dismiss
    @AppStorage("binge.stashUrl") private var stashUrl: String = ""
    private var stashApiKey: String { KeychainStore.shared.stashApiKey }

    @State private var tour = TourDirector.shared
    @State private var saveHaptic = 0
    @State private var service: CollectionsService?
    /// Current per-collection membership for THIS scene. Keyed by
    /// tagName so we don't re-check tag-id resolution every render.
    @State private var memberships: [String: Bool] = [:]
    @State private var pending: Set<String> = []
    @State private var currentTagIds: [String] = []
    @State private var creating: Bool = false
    @State private var newName: String = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if creating {
                        createForm
                    }
                    if let service {
                        ForEach(service.collections) { coll in
                            row(for: coll, service: service)
                            if coll.id != service.collections.last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.06))
                                    .padding(.leading, 60)
                            }
                        }
                    } else {
                        ProgressView()
                            .tint(.white)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.top, 8)
            }
            .background(Color(white: 0.07).ignoresSafeArea())
            .navigationTitle("Save to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
        .bingeHaptic(.success, trigger: saveHaptic)
        .task {
            if service == nil {
                service = CollectionsService(
                    baseURL: stashUrl,
                    apiKey: stashApiKey
                )
            }
            currentTagIds = scene.tags.map(\.id)
            await service?.load()
            await refreshMemberships()
        }
        // Walkthrough: open → tick the first user collection → close,
        // so "add to collection" plays out hands-free.
        .task {
            guard tour.isRunning else { return }
            try? await Task.sleep(for: .seconds(1.1))
            if let coll = service?.collections.first(where: { !$0.isDefault }) {
                await toggle(
                    coll, currentlyOn: memberships[coll.tagName] ?? false
                )
            }
            try? await Task.sleep(for: .seconds(1.6))
            dismiss()
        }
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
                newName.trimmingCharacters(in: .whitespaces).isEmpty
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(
        for coll: CollectionDef,
        service: CollectionsService
    ) -> some View {
        let on = memberships[coll.tagName] ?? false
        let isPending = pending.contains(coll.tagName)
        Button {
            Task { await toggle(coll, currentlyOn: on) }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: iconName(for: coll.icon))
                    .font(.system(size: 18))
                    .foregroundStyle(iconColor(for: coll.icon))
                    .frame(width: 30)
                Text(coll.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                if isPending {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.7)
                } else if on {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.bingeLike)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isPending)
    }

    // MARK: - Actions

    private func toggle(_ coll: CollectionDef, currentlyOn: Bool) async {
        guard let service else { return }
        let next = !currentlyOn
        if next { saveHaptic += 1 }
        // Optimistic flip.
        memberships[coll.tagName] = next
        pending.insert(coll.tagName)
        defer { pending.remove(coll.tagName) }

        let result = await service.setSceneInCollection(
            sceneId: scene.id,
            currentTagIds: currentTagIds,
            collection: coll,
            next: next
        )
        if let r = result {
            memberships[coll.tagName] = r
            // Keep currentTagIds in sync so the next toggle on a
            // different collection uses the updated list.
            if let id = service.tagIds[coll.tagName] {
                if r && !currentTagIds.contains(id) {
                    currentTagIds.append(id)
                } else if !r {
                    currentTagIds.removeAll { $0 == id }
                }
            }
        } else {
            // Roll back the optimistic flip.
            memberships[coll.tagName] = currentlyOn
        }
    }

    private func handleCreate() async {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        _ = await service?.create(name: trimmed)
        newName = ""
        creating = false
        nameFieldFocused = false
        await refreshMemberships()
    }

    /// Recompute membership for every collection by comparing
    /// each one's tag id against the scene's current tag id list.
    /// Default collections (Favourites / Watch Later) may not
    /// have ids yet — they're lazy-created. We resolve on demand
    /// for visible memberships (false until proven true).
    private func refreshMemberships() async {
        guard let service else { return }
        var next: [String: Bool] = [:]
        for coll in service.collections {
            // ?? with an async right-hand side can't use the
            // autoclosure shortcut. Resolve via the cache first;
            // fall through to the async lookup only when needed.
            let id: String?
            if let cached = service.tagIds[coll.tagName] {
                id = cached
            } else {
                id = await service.tagId(for: coll)
            }
            if let id {
                next[coll.tagName] = currentTagIds.contains(id)
            } else {
                next[coll.tagName] = false
            }
        }
        memberships = next
    }

    // MARK: - Icon helpers

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
}
