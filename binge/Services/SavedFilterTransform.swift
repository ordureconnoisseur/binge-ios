import Foundation

/// Stash stores a saved filter's criteria in `object_filter` using its
/// UI's internal shape, which is NOT the shape the GraphQL
/// `findScenes(scene_filter:)` argument expects. Stash's own web UI
/// converts before submitting; binge has to do the same.
///
/// Passing the stored JSON straight through mostly looks like it works,
/// because performer / tag / studio criteria happen to be stored in the
/// input shape already. Anything numeric or scalar is not, and one bad
/// criterion fails the WHOLE query, so the reel comes back empty rather
/// than partially wrong. Measured against the maintainer's seven real
/// saved filters: four failed, three with "cannot use map as Int" or
/// "cannot use map as String".
///
/// Port of web's `src/api/savedFilterTransform.ts`, which was itself
/// written by probing the live schema rather than from memory.
enum SavedFilterTransform {
    /// SceneFilterType fields whose GraphQL input is a raw scalar, not a
    /// criterion object. Each is stored criterion-wrapped, so the inner
    /// value is unwrapped and the modifier dropped.
    private static let scalarFields: Set<String> = [
        "is_missing",
        "has_markers",
        "has_chapters",
        "organized",
        "performer_favorite",
    ]

    /// SceneFilterType fields whose criterion input declares no `value`
    /// field at all: DuplicationCriterionInput, StashIDCriterionInput
    /// and StashIDsCriterionInput. Substituting `value: ""` into one of
    /// these is an unknown-field error that fails the entire query, so a
    /// filter meaning "has no stash id" would return nothing rather than
    /// the scenes it describes.
    private static let valuelessCriterionFields: Set<String> = [
        "duplicated",
        "stash_id_endpoint",
        "stash_ids_endpoint",
    ]

    /// Stored shape to input shape. Returns a value ready to be handed
    /// to `findScenes(scene_filter:)`.
    static func transform(_ objectFilter: JSONValue?) -> [String: Any] {
        guard case .object(let obj)? = objectFilter else { return [:] }
        var out: [String: Any] = [:]

        for (key, val) in obj {
            if case .null = val { continue }

            // Scalar field: unwrap to the inner value, drop the
            // modifier.
            if scalarFields.contains(key) {
                if case .object(let wrapper) = val,
                    let inner = wrapper["value"]
                {
                    out[key] = inner.rawValue
                } else {
                    out[key] = val.rawValue
                }
                continue
            }

            guard case .object(let criterion) = val else {
                out[key] = val.rawValue
                continue
            }

            // Criterion shape: a modifier, and a value that may be
            // absent for the null tests.
            if criterion["modifier"] != nil {
                out[key] = transformCriterion(criterion, field: key)
                continue
            }

            // A shape not seen before. Pass it through: worst case
            // Stash returns a clearer error than a guess would, and
            // that is the signal to extend this.
            out[key] = val.rawValue
        }
        return out
    }

    private static func transformCriterion(
        _ criterion: [String: JSONValue],
        field: String
    ) -> [String: Any] {
        let modifier = criterion["modifier"]?.rawValue ?? NSNull()
        let value = criterion["value"]

        // No value at all, which is how IS_NULL / NOT_NULL are stored.
        // String and Date inputs still require `value: String!`, so an
        // empty string stands in, except where the input type has no
        // value field to stand in for.
        if value == nil || value == .some(.null) {
            if valuelessCriterionFields.contains(field) {
                return ["modifier": modifier]
            }
            return ["modifier": modifier, "value": ""]
        }

        // Numeric and date criteria wrap their value one level deeper
        // than the input expects:
        //   stored { modifier: LESS_THAN, value: { value: 2 } }
        //   input  { modifier: LESS_THAN, value: 2 }
        // Range modifiers keep value2 at that same nested level, so
        // both are flattened together.
        if case .object(let inner)? = value,
            let innerValue = inner["value"],
            // Storage holds at most {value, value2}; anything larger is
            // a different shape and is left alone.
            inner.count <= 2
        {
            var out: [String: Any] = [
                "modifier": modifier,
                "value": innerValue.rawValue,
            ]
            if let v2 = inner["value2"], v2 != .null {
                out["value2"] = v2.rawValue
            }
            return out
        }

        // Already flat: strings, arrays of ids, and so on.
        var out: [String: Any] = [:]
        for (k, v) in criterion { out[k] = v.rawValue }
        return out
    }
}
