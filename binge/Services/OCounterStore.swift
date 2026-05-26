import Foundation

/// Process-wide cache of "the count value we last knew about
/// for this scene", keyed by scene id. Plain class — NOT
/// `@Observable` — so mutations don't trigger SwiftUI view
/// re-renders. That property is the whole point: the previous
/// attempt at "drilled-reel like-count survives LazyVStack
/// recycling" lifted the counter into a parent @State dict,
/// which made every `like` tap re-render every visible
/// SceneSlideView. Reverting to per-cell @State fixed the
/// perf but lost the recycling-survives behaviour.
///
/// This store is the middle ground:
///   - SceneSlideView keeps its per-cell `@State localOCounter`
///     as the rendering source (snappy, no parent re-render).
///   - On `.onAppear`, the cell hydrates `localOCounter` from
///     the store if present (preserves the count when the cell
///     remounts after LazyVStack scrolled it off + back on).
///   - On every local mutation (optimistic increment + server
///     reconcile), the cell writes back to the store so the
///     next remount picks up the latest value.
///
/// Process-lived only — not persisted to disk. The server is
/// the source of truth across launches; this just bridges the
/// SwiftUI view-lifecycle gap during a single session.
@MainActor
final class OCounterStore {
    static let shared = OCounterStore()
    private var counts: [String: Int] = [:]

    private init() {}

    func get(_ sceneId: String) -> Int? {
        counts[sceneId]
    }

    func set(_ sceneId: String, _ value: Int) {
        counts[sceneId] = value
    }
}
