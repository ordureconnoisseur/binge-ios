import SwiftUI

// Top-left of reel slide. Mirrors src/components/PerformerRow.tsx:
// stacked circular avatars (cap 4, "+N" overflow chip), comma-
// joined name label, and a Favourite/Favourited pill.
//
// Favourite toggles the PRIMARY performer's favourite flag via
// performerUpdate. Local @State holds the optimistic value so the
// pill flips immediately; the mutation lands a moment later.
//
// Avatars are tappable too — currently no-op until performer
// profile navigation lands (deferred).
struct ReelPerformerRow: View {
    let performers: [BingeScene.Performer]
    let baseURL: String
    let apiKey: String
    let onPerformerTap: (String) -> Void

    @State private var primaryFavourite: Bool
    @State private var pickerOpen: Bool = false

    init(
        performers: [BingeScene.Performer],
        baseURL: String,
        apiKey: String,
        onPerformerTap: @escaping (String) -> Void
    ) {
        self.performers = performers
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.onPerformerTap = onPerformerTap
        _primaryFavourite = State(
            initialValue: performers.first?.favorite ?? false
        )
    }

    private var visible: [BingeScene.Performer] {
        Array(performers.prefix(4))
    }
    private var overflow: Int { max(0, performers.count - visible.count) }

    private var nameSummary: String {
        let names = performers.map(\.name)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default:
            return "\(names[0..<3].joined(separator: ", ")) +\(names.count - 3) more"
        }
    }

    var body: some View {
        if performers.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 10) {
                stack
                Button {
                    routeTap(performers.first)
                } label: {
                    Text(nameSummary)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .shadow(
                            color: .black.opacity(0.55),
                            radius: 4, x: 0, y: 1
                        )
                }
                .buttonStyle(.plain)
                favouriteButton
            }
            .sheet(isPresented: $pickerOpen) {
                PerformerPickerSheet(
                    performers: performers,
                    baseURL: baseURL,
                    apiKey: apiKey,
                    onPick: { id in onPerformerTap(id) }
                )
            }
        }
    }

    // Tap router — single performer goes straight to that profile;
    // multi-performer opens the picker sheet so the user can choose
    // (matches the web's PerformerSheet pattern). The bubble's own
    // performer is the "default" the picker opens for via the
    // tapped performer's row, but the user can pick any of them.
    private func routeTap(_ tapped: BingeScene.Performer?) {
        if performers.count > 1 {
            pickerOpen = true
        } else if let id = tapped?.id {
            onPerformerTap(id)
        }
    }

    // Bubble sizing — bumped to 40pt to match IG's "story header"
    // weight. Overlap step is roughly bubble × 0.65 so adjacent
    // avatars stay readable while reading as a cluster.
    private static let bubbleSize: CGFloat = 40
    private static let bubbleStep: CGFloat = 26

    // Stacked overlapping circles. Each subsequent avatar nudges
    // bubbleStep to the right (IG-style cluster). Each bubble is a
    // tappable target — tapping it opens THAT performer's profile
    // (not just the primary), which matches web behaviour and is
    // what users expect when there are multiple performers in a
    // scene.
    @ViewBuilder
    private var stack: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(visible.enumerated()), id: \.element.id) {
                idx, performer in
                Button {
                    routeTap(performer)
                } label: {
                    bubble(performer)
                }
                .buttonStyle(.plain)
                .offset(x: CGFloat(idx) * Self.bubbleStep)
                .zIndex(Double(visible.count - idx))
            }
            if overflow > 0 {
                overflowBubble
                    .offset(x: CGFloat(visible.count) * Self.bubbleStep)
                    .zIndex(0)
            }
        }
        .frame(
            width: CGFloat(visible.count + (overflow > 0 ? 1 : 0))
                * Self.bubbleStep
                + (Self.bubbleSize - Self.bubbleStep),
            height: Self.bubbleSize,
            alignment: .leading
        )
    }

    @ViewBuilder
    private func bubble(_ performer: BingeScene.Performer) -> some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.4))
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: Self.bubbleSize, height: Self.bubbleSize)
        .overlay(
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private var overflowBubble: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.7))
            Text("+\(overflow)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: Self.bubbleSize, height: Self.bubbleSize)
        .overlay(
            Circle().stroke(Color.black.opacity(0.5), lineWidth: 1.5)
        )
    }

    @ViewBuilder
    private var favouriteButton: some View {
        Button {
            toggleFavourite()
        } label: {
            Text(primaryFavourite ? "Favourited" : "Favourite")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    primaryFavourite ? .white : Color.black
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        primaryFavourite
                            ? Color.white.opacity(0.18)
                            : Color.white
                    )
                )
                .overlay(
                    Capsule().stroke(
                        primaryFavourite
                            ? Color.white.opacity(0.5)
                            : Color.clear,
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }

    private func toggleFavourite() {
        guard let primary = performers.first else { return }
        let next = !primaryFavourite
        primaryFavourite = next  // optimistic
        Task {
            let client = StashClient(baseURL: baseURL, apiKey: apiKey)
            do {
                let resp: PerformerFavoriteResponse = try await client.gql(
                    Mutations.performerFavorite,
                    variables: ["id": primary.id, "favorite": next]
                )
                // Reconcile with server response — should match
                // optimistic in 99% of cases, but if the server
                // rejected the change for some reason we land in
                // truth.
                primaryFavourite = resp.performerUpdate.favorite
            } catch {
                print(
                    "[binge] favourite[\(primary.id)] failed: \(error)"
                )
                // Roll back optimistic.
                primaryFavourite = !next
            }
        }
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        let trimmed = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return "\(trimmed)\(path)"
    }
}
