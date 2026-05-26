import Foundation
import SwiftUI

// Holds the boot-time sweep of every performer plus the live
// search/filter state. Splits performers into Favourites + Others
// for the UI's two sections.
//
// One-shot load on first mount — performers don't change often.
// Pull-to-refresh re-sweeps. No incremental pagination — the sweep
// already handles pages internally and most libraries fit in a
// few hundred to a couple thousand performers.
// Sort modes for the Following grid. Mirrors src/tabs/Following.tsx
// minus the "last post" sorts (those need cross-source activity
// data — library scene dates + StashDB releases + Reddit posts —
// which the iOS Following tab doesn't fetch yet).
enum FollowingSortMode: String, CaseIterable, Identifiable, Hashable {
    case nameAsc
    case nameDesc
    case scenesDesc
    case scenesAsc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .nameAsc: return "Name A → Z"
        case .nameDesc: return "Name Z → A"
        case .scenesDesc: return "Most scenes"
        case .scenesAsc: return "Fewest scenes"
        }
    }
}

@Observable
@MainActor
final class FollowingViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    var all: [PerformerSummary] = []
    var search: String = ""
    var sort: FollowingSortMode = .nameAsc
    var loadState: LoadState = .idle

    private let baseURL: String
    private let apiKey: String

    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    func load() async {
        if case .loading = loadState { return }
        loadState = .loading
        let client = StashClient(baseURL: baseURL, apiKey: apiKey)
        do {
            let list = try await PerformerSweep.all(client: client)
            all = list
            loadState = .loaded
        } catch {
            loadState = .error(
                (error as? LocalizedError)?.errorDescription ?? "\(error)"
            )
            print("[binge] following sweep failed: \(error)")
        }
    }

    /// Filtered + split + sorted. Computed each access; cheap
    /// enough for the size of typical libraries.
    var sections: (favourites: [PerformerSummary], others: [PerformerSummary]) {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let source: [PerformerSummary] =
            q.isEmpty
            ? all
            : all.filter { $0.name.lowercased().contains(q) }
        var fav: [PerformerSummary] = []
        var oth: [PerformerSummary] = []
        for p in source {
            if p.isFavourite { fav.append(p) } else { oth.append(p) }
        }
        return (sorted(fav), sorted(oth))
    }

    private func sorted(_ list: [PerformerSummary]) -> [PerformerSummary] {
        switch sort {
        case .nameAsc:
            return list.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedAscending
            }
        case .nameDesc:
            return list.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name)
                    == .orderedDescending
            }
        case .scenesDesc:
            return list.sorted { ($0.sceneCount ?? 0) > ($1.sceneCount ?? 0) }
        case .scenesAsc:
            return list.sorted { ($0.sceneCount ?? 0) < ($1.sceneCount ?? 0) }
        }
    }
}
