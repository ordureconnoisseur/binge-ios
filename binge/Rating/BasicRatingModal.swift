import SwiftUI

// Fallback rating sheet — used when the advancedRating plugin
// ISN'T installed/enabled. Drives Stash's native 0–100 rating
// field directly via sceneUpdate / performerUpdate without
// touching tags. Identical user model to Stash's built-in star
// rating: 5 whole stars, tap a star to set, tap the current
// star again to clear.
//
// Visually mirrors the CriterionRatingModal's header so the two
// surfaces feel like the same feature — just simpler. No groups,
// no criteria, no preview formula (since there's no
// per-criterion weighting to combine).
@MainActor
struct BasicRatingModal: View {
    typealias Target = CriterionRatingModal.Target

    let target: Target

    @Environment(\.dismiss) private var dismiss
    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    private var apiKey: String { KeychainStore.shared.stashApiKey }

    @State private var rating100: Int?
    @State private var loading: Bool = true
    @State private var busy: Bool = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                if let error {
                    errorBanner(error)
                }
                preview
                starRow
                Text(
                    "Stash's built-in rating. Install the "
                        + "Advanced Rating plugin for a "
                        + "per-criterion breakdown."
                )
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Rate")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .task { await load() }
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let r = rating100 {
                Text(formatRating(r))
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                Text("/ 10")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                // No rating + no big dash — muted "Not rated"
                // reads cleaner than a giant "— / 10".
                Text(loading ? "Loading…" : "Not rated")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            if busy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            }
        }
    }

    private func formatRating(_ r: Int) -> String {
        let v = Double(r) / 10
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(v))
        }
        return String(format: "%.1f", v)
    }

    // MARK: - Star row

    @ViewBuilder
    private var starRow: some View {
        // Stash stores 0–100 but the canonical UI is 5 whole
        // stars. Each tap sets rating = star * 20. Re-tapping
        // the current top star clears (matches Stash UI).
        let currentStar = (rating100.map { ($0 + 10) / 20 }) ?? 0
        HStack(spacing: 8) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    Task { await setStar(star) }
                } label: {
                    Image(
                        systemName: currentStar >= star
                            ? "star.fill" : "star"
                    )
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(
                        currentStar >= star
                            ? Color.yellow
                            : Color.white.opacity(0.4)
                    )
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
        }
    }

    @ViewBuilder
    private func errorBanner(_ msg: String) -> some View {
        Text(msg)
            .font(.system(size: 12))
            .foregroundStyle(.red.opacity(0.85))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.red.opacity(0.12))
            )
    }

    // MARK: - Load + apply

    private func load() async {
        if !loading { return }
        let svc = RatingService(baseURL: baseURL, apiKey: apiKey)
        switch target {
        case .scene(let id):
            let r = await svc.fetchSceneTagsAndRating(sceneId: id)
            rating100 = r.rating100
        case .performer(let id):
            let r = await svc.fetchPerformerTagsAndRating(performerId: id)
            rating100 = r.rating100
        }
        loading = false
    }

    private func setStar(_ star: Int) async {
        let currentStar = (rating100.map { ($0 + 10) / 20 }) ?? 0
        // Tap on the current top star clears; tap elsewhere sets.
        let newRating: Int? = (currentStar == star) ? nil : star * 20

        // Optimistic local update so the star fill flips before
        // the network round-trip lands.
        let snapshot = rating100
        rating100 = newRating
        busy = true
        defer { busy = false }
        let svc = RatingService(baseURL: baseURL, apiKey: apiKey)
        do {
            let confirmed: Int?
            switch target {
            case .scene(let id):
                confirmed = try await svc.setSceneRating100(
                    sceneId: id, rating: newRating
                )
            case .performer(let id):
                confirmed = try await svc.setPerformerRating100(
                    performerId: id, rating: newRating
                )
            }
            // Trust the server-confirmed value (Stash may snap to
            // its configured precision — e.g. tapping star 3
            // with HALF precision could land at 50 or 60).
            rating100 = confirmed
            error = nil
            NotificationCenter.default.post(
                name: .bingeRatingChanged,
                object: nil,
                userInfo: [
                    "domain": target.domain.rawValue,
                    "id": target.id,
                    "rating100": confirmed as Any,
                ]
            )
        } catch {
            // Roll back on failure.
            rating100 = snapshot
            self.error = "Couldn't save rating. Try again."
            print("[binge] basic rating apply failed: \(error)")
        }
    }
}
