import Foundation

// Full performer record returned by the findPerformer query. Mirrors
// the web's PerformerDetail interface in src/api/queries.ts —
// everything we need to render the profile hero, stats, and bio.
//
// Fields most likely to be nil are typed Optional. The two `count`
// fields are at the schema's Int? level, not 0-defaulted, so we keep
// them optional and render "—" in the UI if nil.
struct PerformerDetail: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let aliasList: [String]
    let favorite: Bool
    let imagePath: String?
    let details: String?
    let country: String?
    let birthdate: String?
    let hairColor: String?
    let eyeColor: String?
    let sceneCount: Int?
    let galleryCount: Int?
    let oCounter: Int?
    /// 0–100 rating from Stash. Surfaced on the profile as a
    /// "Rating" stat (decimal 0.0–10.0 for compact display).
    /// nil when unset; the UI renders "—" in that case.
    let rating100: Int?
    // Social/web fields. `twitter` + `instagram` + `url` are @deprecated
    // in current Stash schema but most installs still populate them;
    // `urls` is the canonical replacement (an unstructured array).
    // We fetch all and merge for chip rendering.
    let twitter: String?
    let instagram: String?
    let url: String?
    let urls: [String]?
    /// External stashbox links — each pairs the endpoint URL
    /// with the performer's id on that box. The stashdb.org
    /// entry is used as the StashDB-mixin discovery seed on the
    /// profile (when the user enables the toggle).
    let stashIds: [StashIdLink]?

    struct StashIdLink: Decodable, Hashable {
        let endpoint: String
        let stashId: String

        enum CodingKeys: String, CodingKey {
            case endpoint
            case stashId = "stash_id"
        }
    }

    /// Convenience — extracts the stash_id that points at
    /// stashdb.org/graphql. nil when the performer isn't linked.
    var stashDBId: String? {
        stashIds?.first(where: {
            $0.endpoint == "https://stashdb.org/graphql"
        })?.stashId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case aliasList = "alias_list"
        case favorite
        case imagePath = "image_path"
        case details
        case country
        case birthdate
        case hairColor = "hair_color"
        case eyeColor = "eye_color"
        case sceneCount = "scene_count"
        case galleryCount = "gallery_count"
        case oCounter = "o_counter"
        case rating100
        case twitter
        case instagram
        case url
        case urls
        case stashIds = "stash_ids"
    }
}

struct FindPerformerResponse: Decodable {
    let findPerformer: PerformerDetail?
}
