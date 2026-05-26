import Foundation

// Subject loader — fetches the underlying scene or performer
// data, builds the LLM context block, pre-fills initial scores
// from existing rating tags, and wraps the save callback.
// Mirrors web's src/scribe/subject.ts so the modal never has to
// branch on subject kind once it has a LoadedSubject.

@MainActor
enum ScribeSubjectLoader {
    static func load(
        ref: SubjectRef, baseURL: String, apiKey: String
    ) async throws -> LoadedSubject? {
        switch ref {
        case .scene(let id):
            return try await loadScene(
                id: id, baseURL: baseURL, apiKey: apiKey
            )
        case .performer(let id):
            return try await loadPerformer(
                id: id, baseURL: baseURL, apiKey: apiKey
            )
        }
    }

    // MARK: - Scene

    private static func loadScene(
        id: String, baseURL: String, apiKey: String
    ) async throws -> LoadedSubject? {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let api = ScribeAPI(baseURL: baseURL, apiKey: apiKey)
        // Let the GraphQL error propagate instead of swallowing
        // via `try?` — the modal surfaces the real cause (schema
        // mismatch, network, etc.) rather than the generic
        // "scene not found".
        async let sceneTask: SceneForScribeResponse =
            try await client.gql(
                Queries.sceneForScribe, variables: ["id": id]
            )
        async let criteriaTask = RatingConfigLoader.shared.load(
            domain: .scene, baseURL: baseURL, apiKey: apiKey
        )
        let resp = try await sceneTask
        let cfg = await criteriaTask
        guard let scene = resp.findScene else { return nil }

        let criteria = cfg.criteria
        let initialScores = api.extractScoresFromTags(
            tags: scene.tags.map { ($0.id, $0.name) },
            criteria: criteria
        )
        let existing = ScribeAPI.readExistingReview(
            customFields: scene.customFields,
            details: scene.details
        )

        return LoadedSubject(
            ref: .scene(id: id),
            title: scene.title.map { "Stash Scribe — \($0)" }
                ?? "Stash Scribe",
            contextStrip: buildSceneContextStrip(scene),
            contextForLLM: describeSceneForLLM(scene),
            existingReview: existing,
            initialScores: initialScores,
            criteria: criteria,
            interviewContract: SCRIBE_INTERVIEW_CONTRACT_SCENE,
            reviewContract: SCRIBE_REVIEW_CONTRACT_SCENE,
            sessionKey: ScribeSessionStore.key(for: .scene(id: id)),
            save: { [scene] args in
                try await api.saveSceneReview(
                    scene: scene,
                    reviewText: args.reviewText,
                    criteria: criteria,
                    scoresByCriterion: args.scoresByCriterion,
                    autoCreate: args.autoCreate
                )
            }
        )
    }

    private static func buildSceneContextStrip(
        _ scene: SceneForScribeResponse.Scene
    ) -> String {
        var bits: [String] = []
        if let n = scene.studio?.name, !n.isEmpty { bits.append(n) }
        let names = scene.performers.compactMap(\.name)
        if !names.isEmpty {
            bits.append(names.joined(separator: " · "))
        }
        let nonRatingTags = scene.tags.filter {
            !isScoreTagName($0.name)
        }
        if !nonRatingTags.isEmpty {
            bits.append("\(nonRatingTags.count) tags")
        }
        return bits.joined(separator: " — ")
    }

    /// LLM context block — performer demographics + user stats +
    /// tags + cleaned synopsis. Mirrors web's
    /// `describeSceneForLLM` (api.ts:L244).
    private static func describeSceneForLLM(
        _ scene: SceneForScribeResponse.Scene
    ) -> String {
        var lines: [String] = []
        if let t = scene.title, !t.isEmpty {
            lines.append("Title: \(t)")
        }
        if let s = scene.studio?.name, !s.isEmpty {
            lines.append("Studio: \(s)")
        }
        if let d = scene.date, !d.isEmpty {
            lines.append("Date: \(d)")
        }

        let perfs = Array(scene.performers.prefix(10))
        if !perfs.isEmpty {
            let perfLines = perfs.compactMap {
                describePerformerInScene($0, sceneDate: scene.date)
            }
            lines.append(perfs.count > 1 ? "Performers:" : "Performer:")
            for pl in perfLines { lines.append("- \(pl)") }
        }

        var userStats: [String] = []
        if let o = scene.oCounter, o > 0 {
            userStats.append("o-counter \(o)")
        }
        if let p = scene.playCount, p > 0 {
            userStats.append("played \(p)×")
        }
        if let r = scene.rating100 {
            userStats.append("already rated \(r)/100")
        }
        if !userStats.isEmpty {
            lines.append(
                "Your history with this scene: "
                    + userStats.joined(separator: ", ")
            )
        }

        let tags = scene.tags
            .map(\.name)
            .filter { !isScoreTagName($0) }
        if !tags.isEmpty {
            lines.append(
                "Tags: \(Array(tags.prefix(25)).joined(separator: ", "))"
            )
        }
        let cleanDetails = ScribeAPI.stripReviewBlock(scene.details)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDetails.isEmpty {
            lines.append(
                "Scene synopsis / existing notes: \(cleanDetails)"
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func describePerformerInScene(
        _ p: SceneForScribeResponse.Scene.Performer,
        sceneDate: String?
    ) -> String? {
        guard let name = p.name, !name.isEmpty else { return nil }
        var tail: [String] = []
        if let age = ageAtDate(
            birthdate: p.birthdate, atDate: sceneDate
        ) {
            tail.append("age \(age) here")
        }
        if let e = p.ethnicity, !e.isEmpty {
            tail.append(e.lowercased())
        }
        if let h = p.hairColor, !h.isEmpty {
            tail.append("\(h.lowercased()) hair")
        }
        if let h = p.heightCm { tail.append("\(h)cm") }
        if let m = p.measurements, !m.isEmpty { tail.append(m) }
        if let f = p.fakeTits, !f.isEmpty {
            tail.append(
                f.lowercased() == "yes" ? "fake tits" : "natural tits"
            )
        }
        if let t = p.tattoos, !t.isEmpty { tail.append("tattooed") }
        if let pi = p.piercings, !pi.isEmpty { tail.append("pierced") }
        if tail.isEmpty { return name }
        return "\(name) (\(tail.joined(separator: ", ")))"
    }

    // MARK: - Performer

    private static func loadPerformer(
        id: String, baseURL: String, apiKey: String
    ) async throws -> LoadedSubject? {
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        let api = ScribeAPI(baseURL: baseURL, apiKey: apiKey)
        // Propagate the profile fetch error explicitly — this is
        // the one that bit us with "Performer not found" when a
        // schema mismatch was the real cause. Scenes-aggregate
        // failures are tolerable (the modal degrades to empty
        // aggregates), so we still try? that one.
        let profileResp: PerformerForScribeResponse = try await client.gql(
            Queries.performerForScribe, variables: ["id": id]
        )
        async let scenesTask: PerformerScenesForScribeResponse =
            (try? await client.gql(
                Queries.performerScenesForScribe,
                variables: ["id": id]
            )) ?? PerformerScenesForScribeResponse(
                findScenes: .init(count: 0, scenes: [])
            )
        async let criteriaTask = RatingConfigLoader.shared.load(
            domain: .performer, baseURL: baseURL, apiKey: apiKey
        )

        let (scenesResp, cfg) = await (scenesTask, criteriaTask)
        guard let performer = profileResp.findPerformer else {
            return nil
        }
        let aggregates = aggregatePerformerScenes(
            scenesResp.findScenes
        )

        let criteria = cfg.criteria
        let initialScores = api.extractScoresFromTags(
            tags: performer.tags.map { ($0.id, $0.name) },
            criteria: criteria
        )
        let existing = ScribeAPI.readExistingReview(
            customFields: performer.customFields,
            details: performer.details
        )

        return LoadedSubject(
            ref: .performer(id: id),
            title: "Stash Scribe — \(performer.name)",
            contextStrip: buildPerformerContextStrip(
                performer, aggregates
            ),
            contextForLLM: describePerformerForLLM(
                performer, aggregates
            ),
            existingReview: existing,
            initialScores: initialScores,
            criteria: criteria,
            interviewContract: SCRIBE_INTERVIEW_CONTRACT_PERFORMER,
            reviewContract: SCRIBE_REVIEW_CONTRACT_PERFORMER,
            sessionKey: ScribeSessionStore.key(for: .performer(id: id)),
            save: { [performer] args in
                try await api.savePerformerReview(
                    performer: performer,
                    reviewText: args.reviewText,
                    criteria: criteria,
                    scoresByCriterion: args.scoresByCriterion,
                    autoCreate: args.autoCreate
                )
            }
        )
    }

    // MARK: - Performer aggregates

    private struct PerformerAggregates {
        let sceneCount: Int
        let totalOCounter: Int
        let ratedCount: Int
        let avgRating: Int?
        let topTags: [String]
        let topStudios: [String]
        let notableScenes:
            [PerformerScenesForScribeResponse.Scene]
    }

    private static func aggregatePerformerScenes(
        _ list: PerformerScenesForScribeResponse.Payload
    ) -> PerformerAggregates {
        let scenes = list.scenes
        let sceneCount = list.count
        let totalO = scenes.reduce(0) { $0 + ($1.oCounter ?? 0) }
        let rated = scenes.filter { $0.rating100 != nil }
        let avgRating: Int?
        if rated.isEmpty {
            avgRating = nil
        } else {
            let sum = rated.reduce(0) { $0 + ($1.rating100 ?? 0) }
            avgRating = Int((Double(sum) / Double(rated.count)).rounded())
        }

        // Tag frequency, excluding score tags.
        var tagFreq: [String: Int] = [:]
        for s in scenes {
            for t in s.tags {
                guard !t.name.isEmpty, !isScoreTagName(t.name)
                else { continue }
                tagFreq[t.name, default: 0] += 1
            }
        }
        let topTags = tagFreq.keys
            .sorted { (a, b) in
                let fa = tagFreq[a] ?? 0
                let fb = tagFreq[b] ?? 0
                if fa != fb { return fa > fb }
                return a < b
            }
            .prefix(10).map { $0 }

        var studioFreq: [String: Int] = [:]
        for s in scenes {
            if let n = s.studio?.name, !n.isEmpty {
                studioFreq[n, default: 0] += 1
            }
        }
        let topStudios = studioFreq.keys
            .sorted { (a, b) in
                let fa = studioFreq[a] ?? 0
                let fb = studioFreq[b] ?? 0
                if fa != fb { return fa > fb }
                return a < b
            }
            .prefix(5).map { $0 }

        // Notable scenes — union of top-3 by rating, o-counter,
        // play-count. Deduped, capped at 8. Same rule as web
        // (api.ts:L655-L687).
        func topN(
            _ arr: [PerformerScenesForScribeResponse.Scene],
            key: KeyPath<
                PerformerScenesForScribeResponse.Scene, Int?
            >,
            n: Int
        ) -> [PerformerScenesForScribeResponse.Scene] {
            return arr
                .filter { ($0[keyPath: key] ?? 0) > 0 }
                .sorted {
                    ($0[keyPath: key] ?? 0) > ($1[keyPath: key] ?? 0)
                }
                .prefix(n).map { $0 }
        }
        var seen: Set<String> = []
        var notable: [PerformerScenesForScribeResponse.Scene] = []
        let candidates =
            topN(scenes, key: \.rating100, n: 3)
            + topN(scenes, key: \.oCounter, n: 3)
            + topN(scenes, key: \.playCount, n: 3)
        for s in candidates {
            if seen.contains(s.id) { continue }
            seen.insert(s.id)
            notable.append(s)
            if notable.count >= 8 { break }
        }

        return PerformerAggregates(
            sceneCount: sceneCount,
            totalOCounter: totalO,
            ratedCount: rated.count,
            avgRating: avgRating,
            topTags: topTags,
            topStudios: topStudios,
            notableScenes: notable
        )
    }

    private static func describePerformerForLLM(
        _ p: PerformerForScribeResponse.Performer,
        _ a: PerformerAggregates
    ) -> String {
        var lines: [String] = []
        lines.append("Name: \(p.name)")
        let aliases = (p.aliasList ?? []).filter {
            !$0.isEmpty && $0 != p.name
        }
        if !aliases.isEmpty {
            lines.append("Aliases: \(aliases.joined(separator: ", "))")
        }
        var demo: [String] = []
        if let g = p.gender, !g.isEmpty {
            demo.append(g.lowercased())
        }
        if let age = ageFromBirthdate(p.birthdate) {
            demo.append(p.deathDate != nil ? "was age \(age)" : "age \(age)")
        }
        if let e = p.ethnicity, !e.isEmpty { demo.append(e) }
        if let c = p.country, !c.isEmpty { demo.append(c) }
        if !demo.isEmpty {
            lines.append("Demographics: \(demo.joined(separator: ", "))")
        }

        var phys: [String] = []
        if let h = p.hairColor, !h.isEmpty { phys.append("hair \(h)") }
        if let e = p.eyeColor, !e.isEmpty { phys.append("eyes \(e)") }
        if let h = p.heightCm { phys.append("\(h)cm") }
        if let w = p.weight { phys.append("\(w)kg") }
        if let m = p.measurements, !m.isEmpty { phys.append(m) }
        if let f = p.fakeTits, !f.isEmpty {
            phys.append(
                f.lowercased() == "yes" ? "fake tits" : "natural tits"
            )
        }
        if !phys.isEmpty {
            lines.append("Physical: \(phys.joined(separator: ", "))")
        }
        if let t = p.tattoos, !t.isEmpty {
            lines.append("Tattoos: \(t)")
        }
        if let pi = p.piercings, !pi.isEmpty {
            lines.append("Piercings: \(pi)")
        }
        if let c = p.careerLength, !c.isEmpty {
            lines.append("Career: \(c)")
        }

        var stats: [String] = ["\(a.sceneCount) scenes in library"]
        if a.totalOCounter > 0 {
            stats.append(
                "Stash o-counter total \(a.totalOCounter) "
                    + "(sum across her scenes — a single scene can "
                    + "contribute multiple)"
            )
        }
        if let avg = a.avgRating {
            stats.append(
                "average rating \(avg)/100 across \(a.ratedCount) "
                    + "scenes you have rated"
            )
        }
        lines.append("Library stats: \(stats.joined(separator: "; "))")
        if !a.topStudios.isEmpty {
            lines.append("Top studios: \(a.topStudios.joined(separator: ", "))")
        }
        if !a.topTags.isEmpty {
            lines.append("Signature tags: \(a.topTags.joined(separator: ", "))")
        }
        if !a.notableScenes.isEmpty {
            lines.append("")
            lines.append(
                "Notable scenes (top by rating / o-count / play-count "
                    + "— reference these specifically in the review):"
            )
            for s in a.notableScenes {
                lines.append(summarizeNotableScene(s))
            }
        }

        let cleanDetails = ScribeAPI.stripReviewBlock(p.details)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDetails.isEmpty {
            lines.append("Bio / existing notes: \(cleanDetails)")
        }
        return lines.joined(separator: "\n")
    }

    private static func summarizeNotableScene(
        _ s: PerformerScenesForScribeResponse.Scene
    ) -> String {
        var lines: [String] = []
        var header: [String] = []
        if let t = s.title, !t.isEmpty { header.append("\"\(t)\"") }
        if let st = s.studio?.name, !st.isEmpty { header.append(st) }
        if let d = s.date, !d.isEmpty { header.append(d) }
        lines.append("• " + header.joined(separator: " — "))
        var stats: [String] = []
        if let r = s.rating100 { stats.append("rating \(r)/100") }
        if let o = s.oCounter, o > 0 { stats.append("\(o) O") }
        if let p = s.playCount, p > 0 { stats.append("\(p) plays") }
        if !stats.isEmpty {
            lines.append("  " + stats.joined(separator: ", "))
        }
        let tags = s.tags.map(\.name).filter {
            !$0.isEmpty && !isScoreTagName($0)
        }
        if !tags.isEmpty {
            lines.append(
                "  tags: " + Array(tags.prefix(8)).joined(separator: ", ")
            )
        }
        // Pull in any existing review for context — same as web.
        let scribeReview: String? = {
            if let cf = s.customFields,
                case .string(let raw) =
                    cf[SCRIBE_REVIEW_FIELD_KEY] ?? .null,
                !raw.isEmpty
            {
                return raw.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            return nil
        }()
        let fromDetails = ScribeAPI.extractReviewFromDetails(s.details)
        let review = scribeReview ?? fromDetails
        let detailsClean = ScribeAPI.stripReviewBlock(s.details)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = review, !r.isEmpty {
            lines.append("  your review: " + truncate(r, max: 400))
        } else if !detailsClean.isEmpty {
            lines.append(
                "  synopsis: " + truncate(detailsClean, max: 300)
            )
        }
        return lines.joined(separator: "\n")
    }

    private static func buildPerformerContextStrip(
        _ p: PerformerForScribeResponse.Performer,
        _ a: PerformerAggregates
    ) -> String {
        var bits: [String] = [p.name]
        if a.sceneCount > 0 { bits.append("\(a.sceneCount) scenes") }
        if a.totalOCounter > 0 { bits.append("\(a.totalOCounter) 💧") }
        if !a.topStudios.isEmpty {
            bits.append(
                a.topStudios.prefix(2).joined(separator: " · ")
            )
        }
        return bits.joined(separator: " — ")
    }
}

// MARK: - Date / string helpers

private func isScoreTagName(_ name: String) -> Bool {
    let range = NSRange(name.startIndex..., in: name)
    return SCRIBE_RATING_TAG_REGEX.firstMatch(in: name, range: range)
        != nil
}

private func ageFromBirthdate(_ birthdate: String?) -> Int? {
    guard let b = birthdate, !b.isEmpty else { return nil }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    guard let bd = f.date(from: String(b.prefix(10))) else {
        return nil
    }
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year], from: bd, to: Date())
    guard let y = comps.year, y >= 0, y < 120 else { return nil }
    return y
}

private func ageAtDate(birthdate: String?, atDate: String?) -> Int? {
    guard let b = birthdate, let d = atDate else { return nil }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    guard
        let bd = f.date(from: String(b.prefix(10))),
        let at = f.date(from: String(d.prefix(10)))
    else { return nil }
    let cal = Calendar(identifier: .gregorian)
    let comps = cal.dateComponents([.year], from: bd, to: at)
    guard let y = comps.year, y >= 0, y < 120 else { return nil }
    return y
}

private func truncate(_ s: String, max: Int) -> String {
    if s.isEmpty || s.count <= max { return s }
    return s.prefix(max - 1)
        .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
}
