import Foundation

// Stash's native saved-filter record. Mirrors StashSavedFilter in
// the web's src/api/queries.ts.
//
// `object_filter` is a GraphQL JSON scalar — its shape depends on
// the filter's mode but for SCENES it matches SceneFilterType keys
// (performers, tags, rating100, etc.). We treat it as an opaque
// JSON object that gets passed straight back to findScenes when
// the user applies a saved filter.
struct StashSavedFilter: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let findFilter: FindFilter?
    let objectFilter: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case findFilter = "find_filter"
        case objectFilter = "object_filter"
    }

    struct FindFilter: Decodable, Hashable {
        let q: String?
        let sort: String?
        let direction: String?
    }
}

struct FindSavedFiltersResponse: Decodable {
    let findSavedFilters: [StashSavedFilter]
}

// Generic JSON value — used to decode + re-serialize the opaque
// `object_filter` field on saved filters. We can't model the field
// statically because the shape depends on which criteria the user
// included when they saved the filter in Stash.
//
// `rawValue` converts back to the [String: Any] / Any tree that
// JSONSerialization understands, so we can pass the deserialized
// object_filter as a GraphQL variable in a subsequent findScenes
// request.
indirect enum JSONValue: Decodable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let arr = try? c.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? c.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    /// Convert back to Foundation-native types suitable for
    /// JSONSerialization (which is what StashClient.gql uses to
    /// encode variables).
    var rawValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n):
            // Stash integer criteria (page, per_page, ratings)
            // serialize as JSON numbers. If the value has no
            // fractional component prefer Int — keeps the wire
            // format clean and avoids `5.0` showing up where the
            // server expects `5`.
            if n.truncatingRemainder(dividingBy: 1) == 0
                && n >= Double(Int.min)
                && n <= Double(Int.max)
            {
                return Int(n)
            }
            return n
        case .string(let s): return s
        case .array(let arr): return arr.map { $0.rawValue }
        case .object(let dict):
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = v.rawValue }
            return out
        }
    }

    /// Convenience: when this value is a top-level object, return
    /// the [String: Any] dict. nil otherwise.
    var asObject: [String: Any]? {
        guard case .object = self else { return nil }
        return rawValue as? [String: Any]
    }
}
