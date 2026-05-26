import SwiftUI

// IG "Collaborators"-style picker. Shown when the user taps a
// performer avatar in the reel performer row and the scene has
// more than one performer — lets the user pick which performer's
// profile to open. Mirrors src/components/PerformerSheet.tsx on
// the web.
//
// Each row exposes a per-row Favourite/Favourited pill so the
// user can favourite a co-performer without leaving the reel.
struct PerformerPickerSheet: View {
    let performers: [BingeScene.Performer]
    let baseURL: String
    let apiKey: String
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(performers) { performer in
                        PerformerPickerRow(
                            performer: performer,
                            baseURL: baseURL,
                            apiKey: apiKey,
                            onPick: { id in
                                dismiss()
                                onPick(id)
                            }
                        )
                        if performer.id != performers.last?.id {
                            Divider()
                                .background(Color.white.opacity(0.06))
                                .padding(.leading, 72)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(white: 0.07).ignoresSafeArea())
            .navigationTitle(
                performers.count > 1 ? "Performers" : "Performer"
            )
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
    }
}

private struct PerformerPickerRow: View {
    let performer: BingeScene.Performer
    let baseURL: String
    let apiKey: String
    let onPick: (String) -> Void

    @State private var favourite: Bool
    @State private var busy: Bool = false

    init(
        performer: BingeScene.Performer,
        baseURL: String,
        apiKey: String,
        onPick: @escaping (String) -> Void
    ) {
        self.performer = performer
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.onPick = onPick
        _favourite = State(initialValue: performer.favorite)
    }

    var body: some View {
        HStack(spacing: 14) {
            avatar
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay(
                    Circle().stroke(
                        Color.white.opacity(0.08),
                        lineWidth: 1
                    )
                )
            Text(performer.name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            favouriteButton
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            onPick(performer.id)
        }
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            if let path = performer.imagePath,
               let url = URL(string: absolute(path)) {
                AuthImageView(
                    url: url,
                    apiKey: apiKey,
                    contentMode: .fill,
                    maxPixel: 256,
                    alignment: .top
                )
                .clipShape(Circle())
            } else {
                Text(String(performer.name.prefix(1)))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    @ViewBuilder
    private var favouriteButton: some View {
        Button {
            toggleFavourite()
        } label: {
            Text(favourite ? "Favourited" : "Favourite")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(favourite ? .white : .black)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        favourite
                            ? Color.white.opacity(0.16)
                            : Color.white
                    )
                )
                .overlay(
                    Capsule().stroke(
                        favourite
                            ? Color.white.opacity(0.4)
                            : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func toggleFavourite() {
        let next = !favourite
        favourite = next
        busy = true
        Task {
            defer { busy = false }
            let client = StashClient(baseURL: baseURL, apiKey: apiKey)
            do {
                let resp: PerformerFavoriteResponse = try await client.gql(
                    Mutations.performerFavorite,
                    variables: [
                        "id": performer.id,
                        "favorite": next,
                    ]
                )
                favourite = resp.performerUpdate.favorite
            } catch {
                print(
                    "[binge] picker favourite[\(performer.id)] failed: \(error)"
                )
                favourite = !next  // roll back
            }
        }
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        let trimmed = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return "\(trimmed)\(path)"
    }
}
