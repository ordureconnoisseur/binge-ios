import SwiftUI

// Per-criterion 5-star rating sheet. Mirrors web's
// CriterionRatingModal — one row per criterion (grouped by the
// plugin's groups), 5-star strip each, weighted-average preview
// at the bottom.
//
// Lifecycle on appear:
//   1. Load plugin config + Stash precision in parallel.
//   2. Read current tags+rating from the entity.
//   3. Parse tags into per-criterion scores → seed the UI.
//
// Tap on a star sets that criterion's score. We immediately:
//   - Optimistically update the local score map (preview number
//     updates in real time).
//   - findScoreTagId(criterion, newScore) — caches per session.
//   - applyTagIds with the new tag list.
//   - re-fetch to pick up the server-side rating100 the plugin
//     hook just recomputed.
//
// On any tag-id miss we abort the write and surface a "tags
// not initialized — open the plugin's settings panel" banner.
@MainActor
struct CriterionRatingModal: View {
    enum Target: Hashable {
        case scene(id: String)
        case performer(id: String)

        var id: String {
            switch self {
            case .scene(let id), .performer(let id): return id
            }
        }
        var domain: RatingDomain {
            switch self {
            case .scene: return .scene
            case .performer: return .performer
            }
        }
    }

    let target: Target

    @Environment(\.dismiss) private var dismiss
    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    private var apiKey: String { KeychainStore.shared.stashApiKey }

    @State private var state: LoadState = .loading
    @State private var pendingCriterionId: String?
    @State private var missingTagWarning: String?
    @State private var scoreHaptic = 0

    enum LoadState {
        case loading
        case ready(
            config: RatingConfig,
            tags: [RatingTag],
            ratings: [String: Int],
            rating100: Int?,
            precision: Int
        )
        case error(String)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.bottom, 30)
            }
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
        .sensoryFeedback(.selection, trigger: scoreHaptic)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        case .ready(let config, _, let ratings, let rating100, _):
            VStack(alignment: .leading, spacing: 18) {
                if let warning = missingTagWarning {
                    warningBanner(warning)
                }
                previewHeader(rating100: rating100, config: config, ratings: ratings)
                ForEach(config.groups) { group in
                    groupSection(group, config: config, ratings: ratings)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
        case .error(let msg):
            VStack(spacing: 8) {
                Text("Couldn't load rating config")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(msg)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 60)
        }
    }

    // MARK: - Preview header

    @ViewBuilder
    private func previewHeader(
        rating100: Int?,
        config: RatingConfig,
        ratings: [String: Int]
    ) -> some View {
        // Use the live local ratings to drive a preview separate
        // from the server-confirmed rating100 — gives a snappy
        // update on each star tap before the round-trip lands.
        let preview = computeRating100(
            ratings: ratings, config: config,
            precision: previewPrecision
        )
        let displayed = preview ?? rating100
        let progress = ratingProgress(
            ratings: ratings, criteria: config.criteria
        )
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let displayed {
                Text(formatRating(displayed))
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                Text("/ 10")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            } else {
                // No rating yet — drop the giant dash. A muted
                // "Not rated" reads as "ready for input" instead
                // of a broken value.
                Text("Not rated")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Text("\(progress.rated)/\(progress.total) rated")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.55))
        }
    }

    /// Snapshot precision read from state — case-guarded helper
    /// so the preview header function above isn't littered with
    /// switch statements.
    private var previewPrecision: Int {
        if case .ready(_, _, _, _, let precision) = state {
            return precision
        }
        return 20
    }

    private func formatRating(_ r: Int) -> String {
        let v = Double(r) / 10
        if v.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(v))
        }
        return String(format: "%.1f", v)
    }

    private func ratingProgress(
        ratings: [String: Int], criteria: [RatingCriterion]
    ) -> (rated: Int, total: Int) {
        var rated = 0
        for c in criteria where ratings[c.id] != nil { rated += 1 }
        return (rated, criteria.count)
    }

    // MARK: - Group section

    @ViewBuilder
    private func groupSection(
        _ group: RatingGroup,
        config: RatingConfig,
        ratings: [String: Int]
    ) -> some View {
        let inGroup = config.criteria.filter { $0.groupId == group.id }
        if !inGroup.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(group.name.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.55))
                ForEach(inGroup) { criterion in
                    criterionRow(
                        criterion,
                        score: ratings[criterion.id]
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func criterionRow(
        _ criterion: RatingCriterion,
        score: Int?
    ) -> some View {
        let isBusy = pendingCriterionId == criterion.id
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(criterion.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !criterion.description.isEmpty {
                    Text(criterion.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }
            Spacer()
            starStrip(
                current: score,
                disabled: isBusy,
                onTap: { newScore in
                    Task { await setScore(criterion: criterion, score: newScore) }
                }
            )
        }
        .padding(.vertical, 6)
        .opacity(isBusy ? 0.6 : 1)
    }

    @ViewBuilder
    private func starStrip(
        current: Int?,
        disabled: Bool,
        onTap: @escaping (Int?) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    // Tap on the current score clears it (toggle);
                    // tap on any other star sets it. Same UX as
                    // web modal.
                    let newScore: Int? =
                        (current == star) ? nil : star
                    onTap(newScore)
                } label: {
                    Image(
                        systemName: (current ?? 0) >= star
                            ? "star.fill" : "star"
                    )
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(
                        (current ?? 0) >= star
                            ? Color.yellow
                            : Color.white.opacity(0.4)
                    )
                }
                .buttonStyle(.plain)
                .disabled(disabled)
            }
        }
    }

    // MARK: - Warning

    @ViewBuilder
    private func warningBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.yellow.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Load + apply

    private func load() async {
        if case .ready = state { return }
        async let configTask = RatingConfigLoader.shared.load(
            domain: target.domain,
            baseURL: baseURL, apiKey: apiKey
        )
        async let precisionTask = RatingPrecisionLoader.shared.load(
            baseURL: baseURL, apiKey: apiKey
        )
        let svc = RatingService(baseURL: baseURL, apiKey: apiKey)
        async let entityTask: (tags: [RatingTag], rating100: Int?) = {
            switch target {
            case .scene(let id):
                return await svc.fetchSceneTagsAndRating(sceneId: id)
            case .performer(let id):
                return await svc.fetchPerformerTagsAndRating(performerId: id)
            }
        }()
        let config = await configTask
        let precision = await precisionTask
        let entity = await entityTask
        let ratings = parseRatingsFromTags(
            entity.tags, criteria: config.criteria
        )
        state = .ready(
            config: config,
            tags: entity.tags,
            ratings: ratings,
            rating100: entity.rating100,
            precision: precision
        )
    }

    private func setScore(
        criterion: RatingCriterion, score: Int?
    ) async {
        scoreHaptic += 1
        guard case .ready(
            let config, var tags, var ratings,
            let oldRating100, let precision
        ) = state else { return }

        // Resolve the score tag id BEFORE optimistic UI so we
        // can surface the missing-tag warning without flicker.
        var newScoreTagId: String?
        let svc = RatingService(baseURL: baseURL, apiKey: apiKey)
        if let s = score {
            newScoreTagId = await svc.findScoreTagId(
                criterion: criterion, score: s
            )
            if newScoreTagId == nil {
                missingTagWarning =
                    "Tag \"\(scoreTagName(criterion: criterion, score: s))\" "
                    + "doesn't exist yet. Open the Advanced Rating "
                    + "plugin's settings panel once to initialize "
                    + "the score-tag tree."
                return
            }
        }

        guard
            let newTagIds = buildUpdatedTagIds(
                currentTags: tags,
                criterion: criterion,
                newScore: score,
                newScoreTagId: newScoreTagId
            )
        else { return }

        // Optimistic local state — preview number bumps before
        // the network lands.
        if let score {
            ratings[criterion.id] = score
        } else {
            ratings.removeValue(forKey: criterion.id)
        }
        missingTagWarning = nil
        pendingCriterionId = criterion.id
        state = .ready(
            config: config, tags: tags, ratings: ratings,
            rating100: oldRating100, precision: precision
        )

        defer { pendingCriterionId = nil }
        do {
            let updatedTags: [RatingTag]
            switch target {
            case .scene(let id):
                updatedTags = try await svc.applySceneTagIds(
                    sceneId: id, tagIds: newTagIds
                )
            case .performer(let id):
                updatedTags = try await svc.applyPerformerTagIds(
                    performerId: id, tagIds: newTagIds
                )
            }
            tags = updatedTags
            // The plugin's hook just recomputed rating100 — re-
            // read to pick up its value (don't trust our local
            // preview which uses our precision interpretation).
            let refreshed: (tags: [RatingTag], rating100: Int?)
            switch target {
            case .scene(let id):
                refreshed = await svc.fetchSceneTagsAndRating(sceneId: id)
            case .performer(let id):
                refreshed = await svc.fetchPerformerTagsAndRating(performerId: id)
            }
            state = .ready(
                config: config,
                tags: refreshed.tags,
                ratings: parseRatingsFromTags(
                    refreshed.tags, criteria: config.criteria
                ),
                rating100: refreshed.rating100,
                precision: precision
            )
            // Notify observers (card chrome, profile header)
            // that this entity's rating moved — they can patch
            // their local state without a fresh GraphQL call.
            NotificationCenter.default.post(
                name: .bingeRatingChanged,
                object: nil,
                userInfo: [
                    "domain": target.domain.rawValue,
                    "id": target.id,
                    "rating100": refreshed.rating100 as Any,
                ]
            )
        } catch {
            // Roll back optimistic state — re-read from server
            // to be safe (some Stash plugins normalize tags on
            // write, so server may differ from filtered-local).
            let rolled: (tags: [RatingTag], rating100: Int?)
            switch target {
            case .scene(let id):
                rolled = await svc.fetchSceneTagsAndRating(sceneId: id)
            case .performer(let id):
                rolled = await svc.fetchPerformerTagsAndRating(performerId: id)
            }
            state = .ready(
                config: config,
                tags: rolled.tags,
                ratings: parseRatingsFromTags(
                    rolled.tags, criteria: config.criteria
                ),
                rating100: rolled.rating100,
                precision: precision
            )
            print("[binge] rating apply failed: \(error)")
        }
    }
}
