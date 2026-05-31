import SwiftUI

/// Drives hands-free, automated walkthroughs of the app for App Store
/// capture. Meaningful only alongside demo mode: the director emits a
/// timed sequence of `TourCommand`s, and each screen observes `tick` and
/// performs the command it owns on its own local state.
///
/// Why `tick` (not just `command`): SwiftUI `.onChange(of:)` won't refire
/// when a value is set to something equal to its previous value — so two
/// consecutive `.reelAdvance`s would only fire once. Views observe the
/// monotonic `tick` and read `command` inside the handler instead.
///
/// Inert when not running (`command` stays nil), so every per-view hook
/// is a no-op in normal use.
///
/// Capture flow: enable Demo content, pick a clip (or the full run) in
/// Settings → Capture, then record. On the Simulator:
///   xcrun simctl status_bar booted override --time "9:41" \
///     --batteryState charged --batteryLevel 100 --cellularBars 4 \
///     --wifiBars 3 --dataNetwork wifi
///   xcrun simctl io booted recordVideo --codec h264 clip.mp4
@Observable
@MainActor
final class TourDirector {
    static let shared = TourDirector()
    private init() {}

    private(set) var command: TourCommand?
    private(set) var tick: Int = 0
    /// Pre-roll countdown (3, 2, 1) shown as an overlay so the user can
    /// start their screen recorder before the run begins. nil = hidden.
    private(set) var countdown: Int?
    private(set) var isRunning = false

    private var task: Task<Void, Never>?

    func start(_ script: TourScript = .full) {
        guard !isRunning else { return }
        isRunning = true
        task = Task { await run(script) }
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

    private func run(_ script: TourScript) async {
        // Pre-roll so the user can hit record.
        for n in [3, 2, 1] {
            countdown = n
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { isRunning = false; countdown = nil; return }
        }
        countdown = nil
        for step in script.steps {
            if Task.isCancelled || !isRunning { break }
            emit(step.command)
            try? await Task.sleep(for: .seconds(step.delay))
        }
        command = nil
        isRunning = false
    }
}

/// One scripted beat. `delay` is the pause AFTER emitting, before the
/// next command — tuned to native animation + dwell durations.
struct TourStep {
    let command: TourCommand
    let delay: Double
}

/// The full walkthrough plus three short single-feature clips sized for
/// App Store preview videos (each well under 30s on its own).
enum TourScript: String, CaseIterable, Identifiable {
    case full
    case stories
    case homeProfile
    case forYou

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Full walkthrough"
        case .stories: return "Clip · Stories"
        case .homeProfile: return "Clip · Home → Profile"
        case .forYou: return "Clip · For You + likes"
        }
    }

    var steps: [TourStep] {
        switch self {
        case .full: return Self.fullSteps
        case .stories: return Self.storiesSteps
        case .homeProfile: return Self.homeProfileSteps
        case .forYou: return Self.forYouSteps
        }
    }

    // Clip 1 — open the stories row and watch a couple play through.
    private static let storiesSteps: [TourStep] = [
        .init(command: .switchTab(.home), delay: 1.0),
        .init(command: .homeScrollStories, delay: 2.2),
        .init(command: .homeOpenStory(0), delay: 9.0),
        .init(command: .homeDismissStory, delay: 1.2),
    ]

    // Clip 2 — scroll the home feed, then open a performer profile.
    private static let homeProfileSteps: [TourStep] = [
        .init(command: .switchTab(.home), delay: 1.0),
        .init(command: .homeScrollFeed, delay: 5.0),
        .init(command: .homeOpenPerformer, delay: 3.5),
        .init(command: .performerFavourite, delay: 2.5),
        .init(command: .performerBack, delay: 1.2),
    ]

    // Clip 3 — scroll the For You reel and like a few.
    private static let forYouSteps: [TourStep] = [
        .init(command: .switchTab(.foryou), delay: 2.4),
        .init(command: .reelLike, delay: 2.0),
        .init(command: .reelAdvance, delay: 2.6),
        .init(command: .reelLike, delay: 2.0),
        .init(command: .reelAdvance, delay: 2.6),
        .init(command: .reelAdvance, delay: 2.6),
        .init(command: .reelLike, delay: 2.2),
    ]

    // The complete tour (every feature, end to end).
    private static let fullSteps: [TourStep] = [
        .init(command: .switchTab(.home), delay: 1.2),
        .init(command: .homeScrollStories, delay: 1.8),
        .init(command: .homeOpenStory(0), delay: 10.5),
        .init(command: .homeDismissStory, delay: 1.0),
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

/// Index-based targets (e.g. `homeWatchFull(2)`) are resolved by the
/// owning view against the deterministic demo content, so the director
/// stays content-agnostic.
enum TourCommand: Equatable {
    case switchTab(BingeTab)
    case homeScrollStories
    case homeOpenStory(Int)
    case homeDismissStory
    case homeScrollFeed
    case homeOpenPerformer
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
