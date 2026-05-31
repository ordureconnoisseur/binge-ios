import SwiftUI

/// Drives a hands-free, automated walkthrough of the app for App Store
/// preview capture. Meaningful only alongside demo mode: the director
/// emits a timed sequence of `TourCommand`s, and each screen observes
/// `tick` and performs the command it owns on its own local state.
///
/// Why `tick` (not just `command`): SwiftUI `.onChange(of:)` won't refire
/// when a value is set to something equal to its previous value — so two
/// consecutive `.reelAdvance`s would only fire once. Views observe the
/// monotonic `tick` and read `command` inside the handler instead.
///
/// Inert when not running (`command` stays nil), so every per-view hook
/// is a no-op in normal use.
///
/// Capture flow: enable Demo content, tap "Run walkthrough" in Settings,
/// then record. On the Simulator the cleanest capture is:
///   xcrun simctl status_bar booted override --time "9:41" \
///     --batteryState charged --batteryLevel 100 --cellularBars 4 \
///     --wifiBars 3 --dataNetwork wifi
///   xcrun simctl io booted recordVideo --codec h264 walkthrough.mp4
@Observable
@MainActor
final class TourDirector {
    static let shared = TourDirector()
    private init() {}

    /// Current command + a monotonic counter. Views observe `tick`.
    private(set) var command: TourCommand?
    private(set) var tick: Int = 0
    /// Pre-roll countdown (3, 2, 1) shown as an overlay so the user can
    /// start their screen recorder before the tour begins. nil = hidden.
    private(set) var countdown: Int?
    private(set) var isRunning = false

    private var task: Task<Void, Never>?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task { await run() }
    }

    func stop() {
        isRunning = false
        countdown = nil
        command = nil
        task?.cancel()
        task = nil
    }

    private func emit(_ c: TourCommand) {
        command = c
        tick += 1
    }

    private func run() async {
        // Pre-roll so the user can hit record.
        for n in [3, 2, 1] {
            countdown = n
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { isRunning = false; countdown = nil; return }
        }
        countdown = nil
        for step in Self.script {
            if Task.isCancelled || !isRunning { break }
            emit(step.command)
            try? await Task.sleep(for: .seconds(step.delay))
        }
        command = nil
        isRunning = false
    }

    private struct Step {
        let command: TourCommand
        /// Pause AFTER emitting, before the next command. Tuned to native
        /// animation + dwell durations so each beat is watchable.
        let delay: Double
    }

    // The scripted sequence, mirroring the requested walkthrough:
    // stories → story → feed → watch-full → like → For You → 3 reels →
    // like → save → performer → favourite → explore+tag → following+
    // performer → menu → saved → collection.
    private static let script: [Step] = [
        .init(command: .switchTab(.home), delay: 1.2),
        .init(command: .homeScrollStories, delay: 1.8),
        // Demo stories are capped to 3 scenes each (1.7s/scene), so this
        // dwell walks through ~2 performers' stories before we dismiss.
        .init(command: .homeOpenStory(0), delay: 10.5),
        .init(command: .homeDismissStory, delay: 1.0),
        // Feed scroll steps through 3 cards (~1.2s each) — give it room.
        .init(command: .homeScrollFeed, delay: 4.8),
        .init(command: .homeWatchFull(2), delay: 2.4),
        .init(command: .reelLike, delay: 2.0),
        .init(command: .homePopReel, delay: 1.2),
        .init(command: .switchTab(.foryou), delay: 1.8),
        .init(command: .reelAdvance, delay: 2.4),
        .init(command: .reelAdvance, delay: 2.4),
        .init(command: .reelAdvance, delay: 2.4),
        .init(command: .reelLike, delay: 2.0),
        .init(command: .reelAddToCollection, delay: 4.2),
        .init(command: .reelOpenPerformer, delay: 2.4),
        .init(command: .performerFavourite, delay: 2.2),
        .init(command: .performerBack, delay: 1.4),
        .init(command: .switchTab(.explore), delay: 2.0),
        .init(command: .exploreTapTag(0), delay: 2.8),
        .init(command: .switchTab(.following), delay: 2.0),
        .init(command: .followingOpenPerformer(0), delay: 2.6),
        .init(command: .performerBack, delay: 1.2),
        .init(command: .switchTab(.menu), delay: 1.6),
        .init(command: .menuOpenSaved, delay: 2.0),
        .init(command: .savedOpenCollection(2), delay: 3.2),
    ]
}

/// One scripted beat. Index-based targets (e.g. `homeWatchFull(2)`,
/// `savedOpenCollection(2)`) are resolved by the owning view against the
/// deterministic demo content, so the director stays content-agnostic.
enum TourCommand: Equatable {
    case switchTab(BingeTab)
    case homeScrollStories
    case homeOpenStory(Int)
    case homeDismissStory
    case homeScrollFeed
    case homeWatchFull(Int)
    case homePopReel
    case reelAdvance
    case reelLike
    case reelAddToCollection
    case reelOpenPerformer
    case performerFavourite
    case performerBack
    case exploreTapTag(Int)
    case followingOpenPerformer(Int)
    case menuOpenSaved
    case savedOpenCollection(Int)
}
