import Foundation

// Shared types for the iOS Scribe port. Mirrors web's
// src/scribe/api.ts + subject.ts type shapes so reviews
// generated in binge-ios and binge-web roundtrip cleanly
// against the same Stash custom_fields key.

/// Single message in the LLM transcript. Same role enum the
/// Ollama chat API uses — system messages bootstrap the
/// persona/contract, user/assistant alternate during interview.
struct LLMMessage: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    let role: Role
    let content: String

    enum Role: String, Codable, Hashable {
        case system, user, assistant
    }

    enum CodingKeys: String, CodingKey {
        case role, content
    }

    init(role: Role, content: String) {
        self.role = role
        self.content = content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decode(Role.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        id = UUID()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
    }

    /// Wire shape for `runPluginOperation` args.messages — just
    /// role + content, no id.
    var wireDict: [String: Any] {
        ["role": role.rawValue, "content": content]
    }
}

enum VoiceMode: String, Codable, CaseIterable, Hashable {
    case direct
    case sensual
    case filthy

    var label: String {
        switch self {
        case .direct: return "Direct"
        case .sensual: return "Sensual"
        case .filthy: return "Filthy"
        }
    }
}

struct ScribeConfig: Hashable {
    let ollamaUrl: String
    let model: String
    let voicePrompts: [VoiceMode: String]
    let defaultTone: VoiceMode
    /// When true and a score tag is missing at save time,
    /// the API creates it (matches web's autoCreateTags).
    /// When false, the save throws with a "open the rating
    /// plugin's settings panel" hint.
    let autoCreateTags: Bool
}

/// What subject the modal opens against. Lifted from web's
/// SubjectRef — drives subject loader branching.
enum SubjectRef: Identifiable, Hashable {
    case scene(id: String)
    case performer(id: String)

    var id: String {
        switch self {
        case .scene(let id): return "scene:\(id)"
        case .performer(let id): return "performer:\(id)"
        }
    }
    var kind: String {
        switch self {
        case .scene: return "scene"
        case .performer: return "performer"
        }
    }
    var rawId: String {
        switch self {
        case .scene(let id), .performer(let id): return id
        }
    }
}

/// What the caller is saying about one criterion.
///
/// A dictionary of plain Int cannot express this. Removing a key to
/// mean "cleared" is indistinguishable from never having set it, and
/// that ambiguity is exactly what went wrong on the web side twice:
/// one version stripped every configured criterion and destroyed the
/// scores it was not given, the next stripped only the ones carrying a
/// number and made clearing a score impossible. Present means the
/// caller owns this criterion; absent means it is not theirs to touch.
enum ScoreIntent: Equatable {
    case set(Int)
    case clear
}

/// Normalised subject the modal renders against — same field
/// set whether the subject is a scene or performer. The closure
/// `save` is the one branch the modal still routes through.
struct LoadedSubject {
    let ref: SubjectRef
    let title: String
    let contextStrip: String
    let contextForLLM: String
    let existingReview: String?
    let initialScores: [String: Int]
    let criteria: [RatingCriterion]
    let interviewContract: String
    let reviewContract: String
    let sessionKey: String
    /// Save closure — captures the underlying scene/performer
    /// payload so the modal doesn't need to know which kind it's
    /// holding when the user taps "Save".
    let save: @MainActor (SaveArgs) async throws -> Void

    struct SaveArgs {
        let reviewText: String
        /// Keyed by criterion id. A criterion present here is one this
        /// save speaks for; one absent is left exactly as it is.
        let scoresByCriterion: [String: ScoreIntent]
        let autoCreate: Bool
    }
}

struct ParsedReview {
    let review: String
    let scores: [String: Int]
}

/// Resumable interview state. Persisted to UserDefaults keyed
/// `stashScribe.session.<kind>.<id>` (same key format as web's
/// localStorage so the two roundtrip when running against the
/// same Stash).
struct ScribeSessionState: Codable, Hashable {
    let messages: [LLMMessage]
    let generated: Generated?

    struct Generated: Codable, Hashable {
        let review: String
        let scores: [String: Int]
    }
}

/// Marker block format embedded into `details` as a fallback
/// when `custom_fields` isn't supported on older Stash. Same
/// HTML-comment delimiters the web uses so reviews roundtrip.
enum ScribeMarkers {
    static let start = "<!--stash-scribe:review:start-->"
    static let end = "<!--stash-scribe:review:end-->"
}

/// Stash custom_fields key the scribe plugin reads/writes.
let SCRIBE_REVIEW_FIELD_KEY = "stashScribe_review"
let SCRIBE_PLUGIN_ID = "stashScribe"

/// Score-tag regex — mirrors web's `RATING_TAG_RE` (api.ts:L24).
/// Captures criterion name (sans " ★") + integer score 0-5.
/// Different from the rating module's `RATING_SCORE_TAG_REGEX`
/// which keeps the ★ in capture 1; we strip here so we can
/// match against criterion.name case-insensitively without
/// renormalising the captured text.
let SCRIBE_RATING_TAG_REGEX = try! NSRegularExpression(
    pattern: #"^(.+?)\s*★\s*:\s*([0-5])$"#
)
