import Foundation

// Shared types for the Advanced Rating criterion system. Mirrors
// the web src/rating/types.ts byte-for-byte so the wire format
// (tag-name encoding "<criterion> ★: <0-5>") stays compatible
// with the plugin's Python hook.
//
// `advancedRating` is a single Stash plugin handling both scene
// AND performer rating with one data model — criteria bucketed
// into groups, each criterion has a 0–5 score recorded as a tag
// on the entity, plugin's Scene.Update.Post / Performer.Update.Post
// hook recomputes rating100 server-side after any tag update.
//
// Within the merged plugin's config dict the two domains are
// namespaced by key prefix: `scene_*` and `performer_*`.

enum RatingDomain: String, Hashable, Codable {
    case scene
    case performer
}

struct RatingGroup: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let weight: Double
}

struct RatingCriterion: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let groupId: String
    let weight: Double
    let enabled: Bool
    let description: String
}

struct RatingConfig: Hashable {
    let domain: RatingDomain
    let groups: [RatingGroup]
    /// Already filtered to `enabled == true` — disabled criteria
    /// shouldn't appear in the modal.
    let criteria: [RatingCriterion]
}

/// Suffix the plugin appends to the criterion's display name to
/// form the tag prefix, e.g. "Production Quality ★". Score tags
/// extend this with ": 0-5". Whitespace-sensitive — DO NOT trim.
let RATING_TAG_SUFFIX = " ★"

/// Regex matching a score tag's value half. Group 1 captures the
/// prefix (criterion name + ★), group 2 captures the score 0-5.
/// Tolerant of stray whitespace around the colon — Stash users
/// occasionally hand-edit tags.
let RATING_SCORE_TAG_REGEX = try! NSRegularExpression(
    pattern: #"^(.+?)\s*:\s*([0-5])$"#
)

/// Tag prefix for a criterion ("Production Quality ★"). The
/// score-bearing tag concatenates ": <score>" onto this.
func criterionTagPrefix(_ c: RatingCriterion) -> String {
    return c.name + RATING_TAG_SUFFIX
}

/// Full score-tag name ("Production Quality ★: 4").
func scoreTagName(criterion c: RatingCriterion, score: Int) -> String {
    return criterionTagPrefix(c) + ": \(score)"
}

/// Minimum tag shape the rating module cares about — just id +
/// name. Existing Stash queries return more but the rating logic
/// only reads these two.
struct RatingTag: Hashable, Codable {
    let id: String
    let name: String
}
