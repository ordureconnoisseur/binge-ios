import Foundation
import SwiftUI

/// Genders the user wants binge's discovery surfaces to surface.
/// Mirrors web's `binge.allowedGenders` localStorage key (CSV of
/// StashDB enum values) so the two clients converge on the same
/// data shape — if the user ever syncs preferences across devices
/// the meaning is portable.
///
/// Storage shape: comma-separated UPPERCASE enum values under the
/// `binge.allowedGenders` UserDefaults key. Empty string is honored
/// as "show nothing" rather than reverting to the default — matches
/// web's read semantics.
enum AllowedGender: String, CaseIterable, Identifiable, Codable, Hashable {
    case female = "FEMALE"
    case male = "MALE"
    case transgenderFemale = "TRANSGENDER_FEMALE"
    case transgenderMale = "TRANSGENDER_MALE"
    case nonBinary = "NON_BINARY"

    var id: String { rawValue }

    /// Human-friendly label used in tooltips / accessibility hints.
    var label: String {
        switch self {
        case .female: return "Female"
        case .male: return "Male"
        case .transgenderFemale: return "Trans female"
        case .transgenderMale: return "Trans male"
        case .nonBinary: return "Non-binary"
        }
    }
}

// `UserDefaults` is thread-safe so the store doesn't need
// MainActor isolation — call sites in DiscoveryFeedBuilder need
// to invoke `currentStrings()` from default parameter values,
// which Swift evaluates without inheriting the caller's actor.
enum AllowedGendersStore {
    static let storageKey = "binge.allowedGenders"
    /// Default = female + trans female. Matches web's default and
    /// binge's historical behaviour before the toggle existed —
    /// existing users see no change until they tweak the setting.
    static let defaults: Set<AllowedGender> = [
        .female, .transgenderFemale,
    ]

    /// Imperative reader used by call sites that aren't SwiftUI
    /// views (DiscoveryFeedBuilder / HomeViewModel.fetchDiscovery
    /// / DiscoverPerformersBar's loader).
    static func current() -> Set<AllowedGender> {
        guard let raw = UserDefaults.standard.string(forKey: storageKey)
        else { return defaults }
        // Honor empty-string as "show nothing" — matches web.
        let parts = raw.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .compactMap(AllowedGender.init(rawValue:))
        return Set(parts)
    }

    /// As string-set for direct comparison with StashDB enum
    /// strings on raw performer records.
    static func currentStrings() -> Set<String> {
        Set(current().map(\.rawValue))
    }

    /// Genders silently hidden everywhere (trans), regardless of the
    /// "Genders to surface" setting — mirrors web's HIDDEN_GENDERS.
    static let hiddenStrings: Set<String> = [
        "TRANSGENDER_FEMALE", "TRANSGENDER_MALE",
    ]

    /// currentStrings() minus the hidden genders — the set actually
    /// surfaced in discovery + the Discover Performers bar.
    static func visibleStrings() -> Set<String> {
        currentStrings().subtracting(hiddenStrings)
    }

    static func write(_ values: Set<AllowedGender>) {
        // Preserve CaseIterable order so the persisted string is
        // stable across writes — helps anyone inspecting UserDefaults.
        let ordered = AllowedGender.allCases
            .filter { values.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
        UserDefaults.standard.set(ordered, forKey: storageKey)
    }
}
