import Foundation

// Per-criterion score extraction + rating100 preview math. Direct
// port of src/rating/ratings.ts — same weighted-group formula
// the plugin's Python hook uses server-side, so the modal's
// preview number matches what the user will see after submit.

/// Read current per-criterion scores from an entity's tags. Tags
/// that match the score pattern but reference a criterion that's
/// not in the active config are ignored (e.g. user disabled a
/// criterion in plugin settings after rating — the tag survives
/// but won't show in the modal).
func parseRatingsFromTags(
    _ tags: [RatingTag],
    criteria: [RatingCriterion]
) -> [String: Int] {
    var byPrefix: [String: RatingCriterion] = [:]
    for c in criteria {
        byPrefix[criterionTagPrefix(c)] = c
    }
    var out: [String: Int] = [:]
    for tag in tags {
        let range = NSRange(tag.name.startIndex..., in: tag.name)
        guard
            let m = RATING_SCORE_TAG_REGEX.firstMatch(
                in: tag.name, range: range
            ),
            m.numberOfRanges >= 3,
            let prefixRange = Range(m.range(at: 1), in: tag.name),
            let scoreRange = Range(m.range(at: 2), in: tag.name),
            let score = Int(tag.name[scoreRange])
        else { continue }
        let prefix = String(tag.name[prefixRange])
            .trimmingCharacters(in: .whitespaces)
        if let c = byPrefix[prefix] {
            out[c.id] = score
        }
    }
    return out
}

/// Build the new tag_ids array for an entity-update mutation.
/// Removes any tag matching the criterion's score pattern (any
/// score) and appends the new score tag's id when one was given.
///
/// Returns nil when the new score tag id can't be resolved —
/// caller surfaces a "tags not initialized" warning rather than
/// writing a wrong tag set.
func buildUpdatedTagIds(
    currentTags: [RatingTag],
    criterion: RatingCriterion,
    newScore: Int?,
    newScoreTagId: String?
) -> [String]? {
    let prefix = criterionTagPrefix(criterion)
    let filtered = currentTags.filter { tag in
        let range = NSRange(tag.name.startIndex..., in: tag.name)
        guard
            let m = RATING_SCORE_TAG_REGEX.firstMatch(
                in: tag.name, range: range
            ),
            m.numberOfRanges >= 2,
            let prefixRange = Range(m.range(at: 1), in: tag.name)
        else {
            return true  // not a score tag — keep
        }
        let tagPrefix = String(tag.name[prefixRange])
            .trimmingCharacters(in: .whitespaces)
        return tagPrefix != prefix
    }
    var result = filtered.map(\.id)
    guard newScore != nil else { return result }
    guard let newScoreTagId else { return nil }
    if !result.contains(newScoreTagId) {
        result.append(newScoreTagId)
    }
    return result
}

/// Weighted-group rating100 preview. Replicates the plugin's
/// formula exactly so the modal preview matches the post-update
/// value. nil when there's nothing to rate (no criterion has a
/// score yet).
func computeRating100(
    ratings: [String: Int],
    config: RatingConfig,
    precision: Int = 20
) -> Int? {
    var criteriaByGroup: [String: [RatingCriterion]] = [:]
    for c in config.criteria {
        criteriaByGroup[c.groupId, default: []].append(c)
    }
    struct GroupContribution {
        let groupWeight: Double
        let groupAvg: Double
    }
    var contribs: [GroupContribution] = []
    for g in config.groups {
        let inGroup = criteriaByGroup[g.id] ?? []
        var weightedScoreSum: Double = 0
        var weightSum: Double = 0
        for c in inGroup {
            guard let score = ratings[c.id] else { continue }
            weightedScoreSum += Double(score) * c.weight
            weightSum += c.weight
        }
        if weightSum > 0 {
            contribs.append(
                .init(
                    groupWeight: g.weight,
                    groupAvg: weightedScoreSum / weightSum
                )
            )
        }
    }
    if contribs.isEmpty { return nil }
    var num: Double = 0
    var den: Double = 0
    for c in contribs {
        num += c.groupAvg * c.groupWeight
        den += c.groupWeight
    }
    if den == 0 { return nil }
    let final05 = num / den
    let safePrecision = precision > 0 ? precision : 20
    // Half-to-even, twice, exactly as the plugin's Python does it. A bare
    // `.rounded()` is half-AWAY-from-zero, which disagrees on every exact
    // half: two criteria scored 2 and 3 average to 2.5, and the modal
    // would preview 60 while the hook stored 40. The second rounding is
    // mathematically a no-op on an integer product, but it stops float
    // error from truncating 59.999... to 59 on the way through Int().
    let raw = (final05 * 20.0) / Double(safePrecision)
    let scaled = raw.rounded(.toNearestOrEven) * Double(safePrecision)
    var rating100 = Int(scaled.rounded(.toNearestOrEven))
    // Floor at one step, not zero. That is the plugin's behaviour and web
    // matches it; a rated scene never reads as unrated.
    rating100 = max(safePrecision, min(100, rating100))
    return rating100
}
