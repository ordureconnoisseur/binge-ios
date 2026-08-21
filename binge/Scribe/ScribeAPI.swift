import Foundation

// Scribe API surface — config loading, LLM bridge,
// review/score parsing, scene + performer save. Direct port of
// web's src/scribe/api.ts. Every network call routes through
// `StashClient.gql<T>` so auth + error decoding stay consistent
// with the rest of the app.
//
// The Scribe plugin is the LLM bridge: callLLM packs the chat
// payload into `runPluginOperation`'s args map; Stash's
// stashScribe.py forwards it to Ollama and returns the
// response atomically. No raw HTTP to Ollama from iOS.

@MainActor
final class ScribeAPI {
    let baseURL: String
    let apiKey: String

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    private var client: StashClient {
        StashClient(baseURL: baseURL, apiKey: apiKey)
    }

    // MARK: - Config

    /// Read the stashScribe plugin's config from
    /// `configuration.plugins.stashScribe`. Falls back to the
    /// hard-coded voice strings + DEFAULT_OLLAMA_URL when keys
    /// are missing. Tone normalization mirrors web (legacy
    /// "vulgar" → filthy, "elegant" → sensual).
    func getScribeConfig() async -> ScribeConfig {
        let raw = await fetchRawPluginConfig()
        let cfg = pluginObject(raw[SCRIBE_PLUGIN_ID])

        // Tone normalization.
        var tone: VoiceMode = .filthy
        if let s = jvString(cfg["defaultTone"]) {
            let lower = s.lowercased()
            if lower == "vulgar" {
                tone = .filthy
            } else if lower == "elegant" {
                tone = .sensual
            } else if let v = VoiceMode(rawValue: lower) {
                tone = v
            }
        }

        let voicePrompts: [VoiceMode: String] = [
            .direct: jvString(cfg["voicePrompt_direct"])
                ?? SCRIBE_DEFAULT_VOICES[.direct]!,
            .sensual: jvString(cfg["voicePrompt_sensual"])
                ?? SCRIBE_DEFAULT_VOICES[.sensual]!,
            // Filthy has a legacy fallback to interviewSystem —
            // some installs only set that one. Matches web
            // (api.ts:141).
            .filthy: jvString(cfg["voicePrompt_filthy"])
                ?? jvString(cfg["interviewSystem"])
                ?? SCRIBE_DEFAULT_VOICES[.filthy]!,
        ]

        let ollamaUrl = (jvString(cfg["ollamaUrl"])
            ?? SCRIBE_DEFAULT_OLLAMA_URL)
            .trimmingCharacters(
                in: .init(charactersIn: "/ \n\r\t")
            )
        let model = jvString(cfg["model"]) ?? SCRIBE_DEFAULT_MODEL
        // autoCreateTags defaults to true (matches web's
        // `cfg.autoCreateTags !== false`).
        let autoCreate: Bool = {
            if let v = cfg["autoCreateTags"],
                case .bool(let b) = v
            {
                return b
            }
            return true
        }()
        return ScribeConfig(
            ollamaUrl: ollamaUrl,
            model: model,
            voicePrompts: voicePrompts,
            defaultTone: tone,
            autoCreateTags: autoCreate
        )
    }

    /// Extract a [String: JSONValue] from a JSONValue.object,
    /// or empty if anything else. Inline because the existing
    /// asObject helper in SavedFilter returns [String: Any].
    private func pluginObject(_ v: JSONValue?)
        -> [String: JSONValue]
    {
        if let v, case .object(let o) = v { return o }
        return [:]
    }

    /// Pull a String value out of a JSONValue.string, else nil.
    private func jvString(_ v: JSONValue?) -> String? {
        if let v, case .string(let s) = v { return s }
        return nil
    }

    private func fetchRawPluginConfig() async -> [String: JSONValue] {
        do {
            let resp: PluginsConfigurationResponse = try await client.gql(
                "query { configuration { plugins } }",
                variables: [:]
            )
            return resp.configuration.plugins
        } catch {
            print("[binge] scribe: plugin config fetch failed: \(error)")
            return [:]
        }
    }

    // MARK: - LLM bridge

    /// Send a transcript to Ollama (via the Scribe plugin) and
    /// return the assistant's reply. Throws on plugin error or
    /// empty content.
    func callLLM(
        messages: [LLMMessage],
        config: ScribeConfig
    ) async throws -> String {
        let args: [String: Any] = [
            "op": "chat",
            "ollamaUrl": config.ollamaUrl,
            "model": config.model,
            "messages": messages.map(\.wireDict),
            "temperature": 0.85,
        ]
        let resp: RunPluginOperationResponse = try await client.gql(
            Mutations.runPluginOperation,
            variables: [
                "plugin_id": SCRIBE_PLUGIN_ID,
                "args": args,
            ]
        )
        guard let payload = resp.runPluginOperation else {
            throw ScribeError("Scribe plugin op returned null")
        }
        if let err = payload.error, !err.isEmpty {
            throw ScribeError(err)
        }
        guard let content = payload.content, !content.isEmpty else {
            throw ScribeError("Ollama returned no content")
        }
        return content
    }

    /// List installed Ollama models (used by future model-picker
    /// UI; v1 modal doesn't expose this).
    func listModels(config: ScribeConfig) async -> [String] {
        let args: [String: Any] = [
            "op": "list_models",
            "ollamaUrl": config.ollamaUrl,
        ]
        do {
            let resp: RunPluginOperationResponse = try await client.gql(
                Mutations.runPluginOperation,
                variables: [
                    "plugin_id": SCRIBE_PLUGIN_ID,
                    "args": args,
                ]
            )
            return resp.runPluginOperation?.models ?? []
        } catch {
            return []
        }
    }

    // MARK: - Parsing

    /// Extract review prose + per-criterion scores from the
    /// LLM's output. Mirrors web's `parseGenerated` (api.ts:L395).
    /// Returns the full body as the review when no REVIEW: marker
    /// is found — degrades gracefully on a poorly-formatted
    /// reply rather than blanking out.
    func parseGenerated(
        body: String, criteria: [RatingCriterion]
    ) -> ParsedReview {
        // Review prose — everything between "REVIEW:" and "SCORES:"
        // (case-insensitive, optional whitespace).
        let reviewBlock: String
        let reviewRe = try! NSRegularExpression(
            pattern: #"REVIEW:\s*([\s\S]*?)(?=\n\s*SCORES\s*:|$)"#,
            options: [.caseInsensitive]
        )
        let bodyRange = NSRange(body.startIndex..., in: body)
        if let match = reviewRe.firstMatch(in: body, range: bodyRange),
            match.numberOfRanges >= 2,
            let r = Range(match.range(at: 1), in: body)
        {
            reviewBlock = String(body[r])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            reviewBlock = body.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        }

        // SCORES block — everything after the first SCORES: hit.
        let scoresBlock: String
        let scoresSplitRe = try! NSRegularExpression(
            pattern: #"SCORES\s*:"#, options: [.caseInsensitive]
        )
        if let first = scoresSplitRe.firstMatch(in: body, range: bodyRange),
            let afterIdx = body.index(
                body.startIndex,
                offsetBy: first.range.upperBound,
                limitedBy: body.endIndex
            )
        {
            scoresBlock = String(body[afterIdx..<body.endIndex])
        } else {
            scoresBlock = ""
        }

        // Line regex — each line is "- Criterion Name: 3" or
        // "* Name — 4". Tolerates leading bullets and separator
        // variants.
        let lineRe = try! NSRegularExpression(
            pattern: #"^[\s•\-*]*(.+?)\s*[:|—-]\s*(\d+(?:\.\d+)?)\s*$"#,
            options: [.anchorsMatchLines, .caseInsensitive]
        )
        var scores: [String: Int] = [:]
        let scoresRange = NSRange(scoresBlock.startIndex..., in: scoresBlock)
        for match in lineRe.matches(in: scoresBlock, range: scoresRange) {
            guard match.numberOfRanges >= 3,
                let nameRange = Range(match.range(at: 1), in: scoresBlock),
                let scoreRange = Range(match.range(at: 2), in: scoresBlock)
            else { continue }
            let rawName = String(scoresBlock[nameRange])
                .trimmingCharacters(in: .whitespaces)
            let rawScore = Double(scoresBlock[scoreRange]) ?? 0
            let clamped = max(0, min(5, Int(rawScore.rounded())))
            // Case-insensitive criterion match.
            if let c = criteria.first(where: {
                $0.name.lowercased() == rawName.lowercased()
            }) {
                scores[c.id] = clamped
            }
        }
        return ParsedReview(review: reviewBlock, scores: scores)
    }

    /// Pre-fill scores from an entity's tags — mirrors web's
    /// `extractScoresFromTags` (api.ts:L327). The web's regex
    /// strips the ★ for case-insensitive name matching; we do
    /// the same here.
    func extractScoresFromTags(
        tags: [(id: String, name: String)],
        criteria: [RatingCriterion]
    ) -> [String: Int] {
        var out: [String: Int] = [:]
        for tag in tags {
            let range = NSRange(tag.name.startIndex..., in: tag.name)
            guard
                let m = SCRIBE_RATING_TAG_REGEX.firstMatch(
                    in: tag.name, range: range
                ),
                m.numberOfRanges >= 3,
                let prefixRange = Range(m.range(at: 1), in: tag.name),
                let scoreRange = Range(m.range(at: 2), in: tag.name),
                let score = Int(tag.name[scoreRange])
            else { continue }
            let name = String(tag.name[prefixRange])
                .trimmingCharacters(in: .whitespaces)
            if let c = criteria.first(where: {
                $0.name.lowercased() == name.lowercased()
            }) {
                out[c.id] = score
            }
        }
        return out
    }

    // MARK: - Review extraction (details marker block)

    /// Read the review embedded in a `details` field as a
    /// fallback when custom_fields isn't present. Same HTML-
    /// marker format as web (ScribeMarkers.start/end).
    static func extractReviewFromDetails(_ details: String?) -> String? {
        guard let d = details,
            let startRange = d.range(of: ScribeMarkers.start),
            let endRange = d.range(
                of: ScribeMarkers.end, range: startRange.upperBound..<d.endIndex
            )
        else { return nil }
        let inner = d[startRange.upperBound..<endRange.lowerBound]
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strip the review marker block from details, returning
    /// the surrounding text. Used at save time so the bio /
    /// synopsis doesn't accumulate stacked review blocks.
    static func stripReviewBlock(_ details: String?) -> String {
        guard let d = details else { return "" }
        guard
            let startRange = d.range(of: ScribeMarkers.start),
            let endRange = d.range(
                of: ScribeMarkers.end, range: startRange.upperBound..<d.endIndex
            )
        else { return d }
        let before = String(d[d.startIndex..<startRange.lowerBound])
            .replacingOccurrences(
                of: #"\s+$"#, with: "", options: .regularExpression
            )
        let after = String(d[endRange.upperBound..<d.endIndex])
            .replacingOccurrences(
                of: #"^\s+"#, with: "", options: .regularExpression
            )
        if before.isEmpty && after.isEmpty { return "" }
        if before.isEmpty { return after }
        if after.isEmpty { return before }
        return "\(before)\n\n\(after)"
    }

    /// Embed the review back into details using the marker
    /// block. Idempotent — strips any prior block first.
    static func appendReviewBlock(
        details: String?, reviewText: String
    ) -> String {
        let stripped = stripReviewBlock(details)
        let review = reviewText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if review.isEmpty { return stripped }
        let block = "\(ScribeMarkers.start)\n\(review)\n\(ScribeMarkers.end)"
        if stripped.isEmpty { return block }
        return "\(stripped)\n\n\(block)"
    }

    // MARK: - Read existing review

    /// Try custom_fields first, then the details marker block.
    static func readExistingReview(
        customFields: [String: JSONValue]?,
        details: String?
    ) -> String? {
        if let cf = customFields,
            case .string(let s) = cf[SCRIBE_REVIEW_FIELD_KEY] ?? .null,
            !s.isEmpty
        {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return extractReviewFromDetails(details)
    }

    // MARK: - Save — scene

    func saveSceneReview(
        scene: SceneForScribeResponse.Scene,
        reviewText: String,
        criteria: [RatingCriterion],
        scoresByCriterion: [String: ScoreIntent],
        autoCreate: Bool
    ) async throws {
        // custom_fields partial — preferred path, matches web
        // (api.ts:L502).
        var input: [String: Any] = [
            "id": scene.id,
            "custom_fields": [
                "partial": [SCRIBE_REVIEW_FIELD_KEY: reviewText]
            ],
        ]
        let cleaned = Self.stripReviewBlock(scene.details)
        if cleaned != (scene.details ?? "") {
            input["details"] = cleaned
        }
        if !scoresByCriterion.isEmpty {
            // Read the scene's tags now rather than using the copy
            // captured when the modal opened. sceneUpdate replaces the
            // whole array, so a write built from a snapshot drops
            // anything added since - by another device, by Stash's own
            // UI, or by the rating plugin's hook.
            let live: FindSceneTagsAndRatingResponse = try await client.gql(
                Queries.findSceneTagsAndRating,
                variables: ["id": scene.id]
            )
            guard let liveTags = live.findScene?.tags else {
                throw ScribeError("That scene could not be read, so its tags were left alone.")
            }
            let newTagIds = try await buildUpdatedTagIds(
                currentTags: liveTags.map { ($0.id, $0.name) },
                criteria: criteria,
                scoresByCriterion: scoresByCriterion,
                autoCreate: autoCreate
            )
            input["tag_ids"] = newTagIds
        }
        let _: EmptyResponse = try await client.gql(
            Mutations.sceneUpdateForScribe,
            variables: ["input": input]
        )
    }

    // MARK: - Save — performer

    func savePerformerReview(
        performer: PerformerForScribeResponse.Performer,
        reviewText: String,
        criteria: [RatingCriterion],
        scoresByCriterion: [String: ScoreIntent],
        autoCreate: Bool
    ) async throws {
        var base: [String: Any] = ["id": performer.id]
        if !scoresByCriterion.isEmpty {
            // Same fresh read as the scene path above.
            let live: FindPerformerTagsAndRatingResponse =
                try await client.gql(
                    Queries.findPerformerTagsAndRating,
                    variables: ["id": performer.id]
                )
            guard let liveTags = live.findPerformer?.tags else {
                throw ScribeError("That performer could not be read, so their tags were left alone.")
            }
            let newTagIds = try await buildUpdatedTagIds(
                currentTags: liveTags.map { ($0.id, $0.name) },
                criteria: criteria,
                scoresByCriterion: scoresByCriterion,
                autoCreate: autoCreate
            )
            base["tag_ids"] = newTagIds
        }
        let cleanedDetails = Self.stripReviewBlock(performer.details)
        let detailsChanged = cleanedDetails != (performer.details ?? "")

        // First attempt: custom_fields path.
        var input = base
        input["custom_fields"] = [
            "partial": [SCRIBE_REVIEW_FIELD_KEY: reviewText]
        ]
        if detailsChanged { input["details"] = cleanedDetails }
        do {
            let _: EmptyResponse = try await client.gql(
                Mutations.performerUpdateForScribe,
                variables: ["input": input]
            )
            return
        } catch let err as StashClientError {
            // Older Stash rejects PerformerUpdateInput.custom_fields
            // — fall back to details-sentinel embedding.
            let msg = (err.errorDescription ?? "").lowercased()
            if !msg.contains("custom_fields") {
                throw err
            }
            print(
                "[binge] scribe: performerUpdate custom_fields "
                    + "rejected, falling back to details block"
            )
        }
        var fallback = base
        fallback["details"] = Self.appendReviewBlock(
            details: cleanedDetails, reviewText: reviewText
        )
        let _: EmptyResponse = try await client.gql(
            Mutations.performerUpdateForScribe,
            variables: ["input": fallback]
        )
    }

    // MARK: - Tag resolution (shared between scene + performer save)

    private func buildUpdatedTagIds(
        currentTags: [(id: String, name: String)],
        criteria: [RatingCriterion],
        scoresByCriterion: [String: ScoreIntent],
        autoCreate: Bool
    ) async throws -> [String] {
        // Only the criteria this save speaks for lose their old score
        // tag. Every configured criterion used to be dropped here and
        // only the supplied ones re-added, so saving a review with a
        // subset of scores deleted the rest: generating a review on a
        // scene rated across eight criteria kept whatever the model
        // happened to mention and destroyed the others, and the
        // Advanced Rating hook then recomputed the rating from what
        // survived. Tags for criteria nobody has configured are left
        // alone either way; they are not ours to delete.
        let owned = Set(
            criteria
                .filter { scoresByCriterion[$0.id] != nil }
                .map(\.name)
        )
        let keep = currentTags.filter { tag in
            let range = NSRange(tag.name.startIndex..., in: tag.name)
            guard
                let m = SCRIBE_RATING_TAG_REGEX.firstMatch(
                    in: tag.name, range: range
                ),
                let nameRange = Range(m.range(at: 1), in: tag.name)
            else {
                return true
            }
            let captured = String(tag.name[nameRange])
                .trimmingCharacters(in: .whitespaces)
            // Keep unless this save speaks for that criterion.
            return !owned.contains(captured)
        }
        var newTagIds = keep.map(\.id)
        for c in criteria {
            // .clear is owned above and simply not re-added.
            guard case .set(let score)? = scoresByCriterion[c.id] else {
                continue
            }
            let tagName = "\(c.name)\(RATING_TAG_SUFFIX): \(score)"
            var tagId = try await findTagIdByName(tagName)
            if tagId == nil {
                if !autoCreate {
                    throw ScribeError(
                        "Tag \"\(tagName)\" doesn't exist. Open the "
                            + "Advanced Rating plugin's settings panel "
                            + "once so it creates the level tags, or "
                            + "enable \"Auto-create missing criterion "
                            + "tags\" in Stash Scribe settings."
                    )
                }
                tagId = try await createTag(name: tagName)
            }
            if let id = tagId, !newTagIds.contains(id) {
                newTagIds.append(id)
            }
        }
        return newTagIds
    }

    private func findTagIdByName(_ name: String) async throws -> String? {
        let resp: ScribeFindTagResponse = try await client.gql(
            Mutations.scribeFindTagByName,
            variables: ["name": name]
        )
        return resp.findTags.tags.first(where: { $0.name == name })?.id
    }

    private func createTag(name: String) async throws -> String {
        let resp: ScribeTagCreateResponse = try await client.gql(
            Mutations.scribeTagCreate,
            variables: [
                "input": [
                    "name": name,
                    "ignore_auto_tag": true,
                ]
            ]
        )
        return resp.tagCreate.id
    }
}

/// Simple Error wrapper so we can throw human-readable strings
/// out of the API layer and let the modal surface them verbatim.
struct ScribeError: LocalizedError {
    let message: String
    init(_ m: String) { self.message = m }
    var errorDescription: String? { message }
}

/// Minimal Decodable for mutations whose return shape we don't
/// inspect — we just want gql<T> to succeed.
private struct EmptyResponse: Decodable {}

