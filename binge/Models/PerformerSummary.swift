import Foundation

// Slim performer record returned by the findPerformers sweep that
// powers the Following page. Mirrors the web's PerformerSummary
// interface in src/api/queries.ts.
//
// `favorite` is optional because Stash's schema has it as
// `Boolean | null`; we default to false in the UI when nil.
struct PerformerSummary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let imagePath: String?
    let sceneCount: Int?
    let favorite: Bool?

    var isFavourite: Bool { favorite ?? false }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case imagePath = "image_path"
        case sceneCount = "scene_count"
        case favorite
    }
}

struct FindPerformersResponse: Decodable {
    let findPerformers: Payload
    struct Payload: Decodable {
        let count: Int
        let performers: [PerformerSummary]
    }
}
