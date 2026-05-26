import SwiftUI

// Global open-modal handle. Any view can call
// `ScribeContext.shared.openScene(id)` or `.openPerformer(id)`;
// `RootView` mounts a single `.sheet(item:)` bound to
// `presented` so the modal lives in one place and dismisses
// cleanly regardless of which surface opened it.
//
// Mirrors the web's ScribeContext / useScribeModal pattern.
@Observable
@MainActor
final class ScribeContext {
    static let shared = ScribeContext()

    /// `nil` = no modal. Set to a SubjectRef to open. RootView's
    /// `.sheet(item:)` re-renders accordingly.
    var presented: SubjectRef?

    private init() {}

    func openScene(_ sceneId: String) {
        presented = .scene(id: sceneId)
    }

    func openPerformer(_ performerId: String) {
        presented = .performer(id: performerId)
    }

    func close() {
        presented = nil
    }
}
