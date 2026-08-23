import AVKit
import SwiftUI

// IG-style viewer that walks through a performer's `scenes` array
// sequentially. Library scenes play their preview clip via
// AVPlayer; StashDB scenes show their cover image for a fixed
// duration before auto-advancing, with a "View on StashDB" link
// for the user to open the source.
//
// Tap-right → next; tap-left → previous; auto-advance on
// playback-end (library) or 5s timer (stashdb). Progress strip at
// the top shows scene N of M and animates the active segment's
// fill. End of last performer's scenes → dismiss.
//
// Fresh AVPlayer per library-scene swap (same rationale as
// SceneVideoSheet — pool reuse here would thrash the reel's LRU).
struct StoryViewerSheet: View {
    let stories: [Story]
    let startIndex: Int
    let baseURL: String
    let apiKey: String
    /// Library-scene "Watch full scene" handoff. Caller pins the
    /// reel to `scene` with `queue` as the deterministic
    /// timeline behind it, switches to the For You tab, and
    /// dismisses this sheet. Mirrors web's library handleCta.
    var onWatchFullScene: ((BingeScene, [BingeScene]) -> Void)? =
        nil

    @Environment(\.dismiss) private var dismiss
    // Mute functionality removed for now — playback is always unmuted.
    private let muted = false

    @Environment(\.scenePhase) private var scenePhase

    @State private var storyIndex: Int
    @State private var sceneIndex: Int = 0
    /// Horizontal travel of an in-progress swipe between performers.
    /// Drives the fold, so the page turns under the finger rather than
    /// waiting for it to lift.
    @State private var dragX: CGFloat = 0
    /// True while the commit animation runs, so a second swipe cannot
    /// start mid-turn and leave the index and the offset disagreeing.
    @State private var turning = false
    /// When the fold began, so a completion handler that never
    /// runs cannot latch swiping off permanently.
    @State private var turningSince: Date?
    @State private var player: AVPlayer?
    @State private var endObserver: NSObjectProtocol?
    @State private var timeObserver: Any?
    @State private var progress: Double = 0
    @State private var loading: Bool = true
    /// Timer-driven advance for stashdb scenes (image-only, no
    /// AVPlayer end event). Cancelled on scene change / teardown.
    @State private var stashDBTimer: Task<Void, Never>?
    /// Wall-clock watchdog for video stories (and the no-media
    /// fallback) so a dead / slow / stalled stream can't hang the
    /// viewer on the spinner forever. Cancelled on teardown.
    @State private var capTimer: Task<Void, Never>?
    /// Guards a scene from auto-advancing twice (a video's
    /// didPlayToEndTime racing its watchdog cap). Reset per scene.
    @State private var didAutoAdvance: Bool = false
    /// Performer profile cover — set when the user taps the
    /// header avatar/name to drill into that profile. Pauses
    /// the underlying player while presented.
    @State private var presentedPerformerId: String?
    /// Save-to-Stash status for the current social scene. Reset per
    /// scene in loadScene(). Tapping Save also pauses auto-advance so
    /// the result has time to land.
    /// Keyed by scene id, and NOT reset when the scene changes.
    ///
    /// A single value reset in loadScene() meant the button forgot it
    /// had already saved: tap Save, let it finish, tap next then back,
    /// and it reads "Save to Stash" again - so a second tap re-downloads
    /// the media and adds a second copy to the library. Nothing marks a
    /// post as saved anywhere else, so the state has to live for the
    /// sheet's lifetime.
    /// Set by goPrev so the storyIndex handler lands on the previous
    /// performer's last scene rather than their first.
    /// Wall-clock time this slide spent with the app in the background.
    ///
    /// Every timer here measures Date().timeIntervalSince(start), and
    /// iOS suspends the process on background - so leaving for a minute
    /// and coming back made the first wake compute elapsed >= total and
    /// advance immediately. The slide you were on was gone before you
    /// saw it. Subtracting the time we were away is the same thing the
    /// web viewer does with its paused accumulator.
    /// The cap most recently armed, so it can be re-armed against what
    /// is left rather than starting over.
    @State private var capDuration: Double = 0
    @State private var backgroundDebt: TimeInterval = 0
    @State private var leftForegroundAt: Date?

    @State private var pendingLastScene = false

    @State private var saveStates: [String: SaveState] = [:]

    /// The save state of the scene on screen.
    private var currentSaveState: SaveState {
        guard let id = currentScene?.id else { return .idle }
        return saveStates[id] ?? .idle
    }

    private func setSaveState(_ state: SaveState, for id: String?) {
        guard let id else { return }
        saveStates[id] = state
    }
    @State private var tour = TourDirector.shared

    enum SaveState: Equatable {
        case idle, saving, saved, failed(String)
    }

    /// How long a StashDB cover stays on screen before auto-
    /// advance. 5s matches the web plugin's image-story cap.
    private static let stashDBDuration: Double = 5.0
    /// Reddit image / text / link kinds share the same 5s timer.
    /// Video kind uses AVPlayer didPlayToEndTime like library
    /// scenes (no timer).
    private static let redditTimedDuration: Double = 5.0
    /// Wall-clock cap for a video story (library preview / reddit
    /// video). Matches web's PREVIEW_CAP_MS — guarantees auto-
    /// advance even if the video never starts, stalls, or runs
    /// longer than this.
    private static let videoCapDuration: Double = 15.0
    /// Fallback for a library scene with no playable media (no
    /// preview + no stream): clear the spinner and advance after a
    /// brief beat instead of hanging forever.
    private static let noMediaCapDuration: Double = 4.0
    /// Demo stories have no real video — each scene gets a short timed
    /// advance so the story visibly walks through its segments.
    private static let demoStoryDuration: Double = 1.7

    init(
        stories: [Story],
        startIndex: Int,
        baseURL: String,
        apiKey: String,
        onWatchFullScene: (
            (BingeScene, [BingeScene]) -> Void
        )? = nil
    ) {
        self.stories = stories
        self.startIndex = startIndex
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.onWatchFullScene = onWatchFullScene
        _storyIndex = State(initialValue: startIndex)
    }

    private var currentStory: Story? {
        stories.indices.contains(storyIndex) ? stories[storyIndex] : nil
    }
    private var currentScene: StoryScene? {
        guard let s = currentStory,
              s.scenes.indices.contains(sceneIndex) else { return nil }
        return s.scenes[sceneIndex]
    }

    var body: some View {
        // The GeometryReader itself keeps its safe area, so it can
        // report the inset; the stack inside it ignores it, so the
        // panels still fill the screen. Ignoring it out here instead
        // took the progress strip and the header up under the Dynamic
        // Island with everything else.
        GeometryReader { geo in
            bodyStack(
                width: geo.size.width,
                topInset: geo.safeAreaInsets.top
            )
            .gesture(performerSwipe(width: geo.size.width))
            .ignoresSafeArea()
        }
    }

    /// A swipe between people, drawn as a fold rather than a slide.
    ///
    /// Two panels hinge on the edge between them: the one you are
    /// leaving rotates away around its far edge while the one arriving
    /// rotates in around the near one, both under perspective, so the
    /// pair reads as two faces of a turning solid. It matches what a
    /// swipe between people does everywhere else, and unlike a slide it
    /// says which direction you came from.
    ///
    /// The arriving panel is a still, not a live story: it is on screen
    /// for a quarter of a second, and standing up a second video player
    /// for that would cost far more than it shows.
    @ViewBuilder
    private func bodyStack(width: CGFloat, topInset: CGFloat) -> some View {
        let progressX = width > 0 ? dragX / width : 0
        ZStack {
            Color.black.ignoresSafeArea()
            if let neighbour = neighbourStory {
                storyCover(neighbour, topInset: topInset)
                    .rotation3DEffect(
                        .degrees(Double(progressX) * 90 + (dragX < 0 ? 90 : -90)),
                        axis: (x: 0, y: 1, z: 0),
                        anchor: dragX < 0 ? .leading : .trailing,
                        perspective: 0.55
                    )
                    .offset(x: dragX + (dragX < 0 ? width : -width))
            }
            currentPanel(topInset: topInset)
                .rotation3DEffect(
                    .degrees(Double(progressX) * 90),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: dragX < 0 ? .trailing : .leading,
                    perspective: 0.55
                )
                .offset(x: dragX)
        }
    }

    private var neighbourStory: Story? {
        if dragX < 0 {
            return stories.indices.contains(storyIndex + 1)
                ? stories[storyIndex + 1] : nil
        }
        if dragX > 0 {
            return stories.indices.contains(storyIndex - 1)
                ? stories[storyIndex - 1] : nil
        }
        return nil
    }

    /// A still of the performer being swiped towards. Their avatar and
    /// name over the first cover in their set, which is enough to know
    /// who is coming.
    @ViewBuilder
    private func storyCover(_ story: Story, topInset: CGFloat) -> some View {
        ZStack {
            Color.black
            if let url = coverURL(for: story) {
                AuthImageView(
                    url: url,
                    apiKey: apiKey,
                    contentMode: .fill,
                    maxPixel: 512
                )
            }
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .center
            )
            VStack {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.3))
                        if let img = story.performer.imagePath,
                            let url = URL(string: absolute(img))
                        {
                            AuthImageView(
                                url: url,
                                apiKey: apiKey,
                                contentMode: .fill,
                                maxPixel: 256
                            )
                            .clipShape(Circle())
                        }
                    }
                    .frame(width: 28, height: 28)
                    Text(story.performer.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 14)
                // Sit the incoming header where the real one sits, or
                // the name jumps down as the fold closes.
                .padding(.top, topInset + 14)
                Spacer()
            }
        }
        .clipped()
    }

    /// First cover in a performer's set, whatever kind of story it is.
    private func coverURL(for story: Story) -> URL? {
        switch story.scenes.first {
        case .library(let scene):
            return scene.screenshotURL(base: baseURL)
        case .stashDB(let s):
            return URL(string: s.coverUrl ?? "")
        case .reddit(let p):
            return URL(string: p.thumbUrl ?? p.mediaUrl ?? "")
        case .none:
            return nil
        }
    }

    private func performerSwipe(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { v in
                // `turning` is cleared only by the fold animation's
                // completion handler. If that ever fails to run, both
                // halves of this gesture bail forever and performer
                // swiping is dead for the life of the sheet, so the
                // latch is given an age as well as a flag.
                if turning, let since = turningSince,
                    Date().timeIntervalSince(since) > 2
                {
                    turning = false
                    turningSince = nil
                }
                guard !turning else { return }
                // Vertical drags belong to dismissal, not to this.
                guard abs(v.translation.width) > abs(v.translation.height)
                else { return }
                // Resist at the ends so the set has edges you can feel
                // rather than a fold that opens onto nothing.
                let raw = v.translation.width
                let atStart = storyIndex == 0 && raw > 0
                let atEnd = storyIndex == stories.count - 1 && raw < 0
                dragX = (atStart || atEnd) ? raw * 0.25 : raw
            }
            .onEnded { v in
                guard !turning else { return }
                let raw = v.translation.width
                let flung = abs(v.predictedEndTranslation.width) > width * 0.4
                let far = abs(raw) > width * 0.28
                let forward = raw < 0
                let canGo =
                    forward
                    ? storyIndex < stories.count - 1
                    : storyIndex > 0
                guard (far || flung), canGo, abs(raw) > 0 else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dragX = 0
                    }
                    return
                }
                turning = true
                turningSince = Date()
                withAnimation(.easeOut(duration: 0.26)) {
                    dragX = forward ? -width : width
                } completion: {
                    // Swap the page only once the fold has closed, then
                    // drop the offset with no animation. Doing both at
                    // once would jump: the content would become the new
                    // performer while still rotated away.
                    storyIndex += forward ? 1 : -1
                    // sceneIndex is left to the storyIndex handler.
                    // Zeroing it here fired the sceneIndex handler too,
                    // so a swipe between performers built a player and
                    // its observers, tore them down and built them
                    // again.
                    dragX = 0
                    turning = false
                }
            }
    }

    @ViewBuilder
    private func currentPanel(topInset: CGFloat) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            if loading {
                BingeLoading()
            }
            // Tap zones — left third = previous, right two-thirds =
            // next. 30/70 split reduces accidental back-taps.
            GeometryReader { g in
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { goPrev() }
                        .frame(width: g.size.width * 0.30)
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { goNext() }
                        .frame(maxWidth: .infinity)
                }
            }
            VStack {
                if let s = currentStory {
                    StoryProgressStrip(
                        sceneCount: s.scenes.count,
                        currentIndex: sceneIndex,
                        progress: progress
                    )
                    .padding(.horizontal, 8)
                    // The panel bleeds under the status bar so the fold
                    // turns the whole screen, so the chrome has to step
                    // back down past it by hand.
                    .padding(.top, topInset + 6)
                    header(for: s)
                }
                Spacer()
                if case .library(let scene) = currentScene {
                    libraryFooter(scene)
                }
                if case .stashDB(let sb) = currentScene {
                    stashDBFooter(sb)
                }
                if case .reddit(let post) = currentScene {
                    redditFooter(post)
                }
            }
        }
        .onAppear { loadScene() }
        .onDisappear { teardown() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                guard let away = leftForegroundAt else { return }
                backgroundDebt += Date().timeIntervalSince(away)
                leftForegroundAt = nil
                // The watchdog sleeps on a clock that keeps running
                // while the process is suspended, so it would fire the
                // moment we return however long is really left. Re-armed
                // against what remains of this slide.
                rearmCapAfterBackground()
            } else if leftForegroundAt == nil {
                leftForegroundAt = Date()
            }
        }
        .statusBarHidden(tour.isRunning)
        // Both indices in one handler. Moving to another performer set
        // sceneIndex to 0, which fired the second handler as well, so
        // every performer change built an AVPlayer and its observers,
        // tore them down and built them again. Harmless but wasteful,
        // on the most expensive transition the sheet has.
        .onChange(of: storyIndex) { _, _ in
            // Owns the reset, so there is exactly one load per change.
            // When sceneIndex is already 0 the handler below will not
            // fire, so this one loads; when it is not, setting it fires
            // that handler instead.
            let target =
                pendingLastScene
                ? max(0, (currentStory?.scenes.count ?? 1) - 1)
                : 0
            pendingLastScene = false
            if sceneIndex == target {
                loadScene()
            } else {
                sceneIndex = target
            }
        }
        .onChange(of: sceneIndex) { _, _ in loadScene() }
        // Pause the underlying player while the performer
        // profile is covering the story — same pattern
        // SceneSlideView uses for its nested sheets so the
        // AVPlayer doesn't keep decoding behind the cover.
        .onChange(of: presentedPerformerId) { _, newId in
            if newId != nil {
                player?.pause()
                stashDBTimer?.cancel()
                capTimer?.cancel()
            } else {
                player?.play()
                // Re-arm timer-driven kinds on dismiss so the
                // user can continue browsing where they left off.
                if case .stashDB(let sb) = currentScene {
                    loadStashDB(sb)
                } else if case .reddit(let post) = currentScene,
                    post.kind != .video
                {
                    loadReddit(post)
                } else {
                    // library / reddit-video: player resumed above;
                    // re-arm the preview watchdog.
                    armCap(after: Self.videoCapDuration)
                }
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { presentedPerformerId != nil },
                set: { if !$0 { presentedPerformerId = nil } }
            )
        ) {
            if let id = presentedPerformerId {
                PerformerProfileSheet(performerId: id)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch currentScene {
        case .library(let scene):
            if DemoMode.isOn {
                // No real video in demo — fill the story with an animated
                // gradient instead of a black screen.
                AnimatedDemoGradient(seed: scene.id).ignoresSafeArea()
            } else if let player {
                VideoPlayerView(player: player).ignoresSafeArea()
            }
        case .stashDB(let sb):
            stashDBCover(sb)
        case .reddit(let post):
            redditContent(post)
        case .none:
            EmptyView()
        }
    }

    /// Reddit kind switch — image / video / text / link each get
    /// their own layout. Video reuses the library AVPlayer view;
    /// the others render as full-screen image or styled text card.
    @ViewBuilder
    private func redditContent(_ post: RedditStoryPost) -> some View {
        switch post.kind {
        case .video:
            if let player {
                VideoPlayerView(player: player).ignoresSafeArea()
            }
        case .image:
            ZStack {
                Color.black
                if let urlStr = post.mediaUrl,
                    let url = URL(string: urlStr)
                {
                    // Reddit-hosted (proxied) and other public CDN
                    // images. Empty apiKey skips the Stash header.
                    AuthImageView(
                        url: url,
                        apiKey: "",
                        contentMode: .fit,
                        maxPixel: 1600
                    )
                } else if let thumb = post.thumbUrl,
                    let url = URL(string: thumb)
                {
                    AuthImageView(
                        url: url, apiKey: "",
                        contentMode: .fit, maxPixel: 1200
                    )
                }
            }
            .ignoresSafeArea()
        case .text:
            redditTextCard(post)
        case .link:
            redditLinkCard(post)
        }
    }

    /// Reddit text post — title heading + body paragraph on a
    /// muted card. Centered vertically; max-width so wide phones
    /// don't get a hard-to-read full-bleed paragraph.
    @ViewBuilder
    private func redditTextCard(_ post: RedditStoryPost) -> some View {
        ZStack {
            Color.black
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let title = post.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    if let body = post.body, !body.isEmpty {
                        Text(body)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if let domain = post.domain {
                        Text(domain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
            .frame(maxWidth: 600)
        }
    }

    /// Reddit link post — thumb (if present) + title + a chevron
    /// CTA. Tapping the card itself opens the link in Safari.
    @ViewBuilder
    private func redditLinkCard(_ post: RedditStoryPost) -> some View {
        ZStack {
            Color.black
            VStack(spacing: 16) {
                if let thumb = post.thumbUrl,
                    let url = URL(string: thumb)
                {
                    AuthImageView(
                        url: url, apiKey: "",
                        contentMode: .fit, maxPixel: 1200
                    )
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if let title = post.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                if let domain = post.domain {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                            .font(.system(size: 12, weight: .semibold))
                        Text(domain)
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func stashDBCover(_ sb: StashDBStoryScene) -> some View {
        ZStack {
            Color.black
            if let urlStr = sb.coverUrl, let url = URL(string: urlStr) {
                // StashDB-hosted public URL — AuthImageView with
                // empty apiKey bypasses the ApiKey header and
                // just fetches normally, while still applying
                // downsampling.
                AuthImageView(
                    url: url,
                    apiKey: "",
                    contentMode: .fit,
                    maxPixel: 1200
                )
            }
        }
        .ignoresSafeArea()
    }

    /// Social footer (reddit / X / pornhub — they all map onto the
    /// reddit-shaped scene). Title (for media kinds) + a domain-aware
    /// "View on …" CTA + a Save-to-Stash button when the post carries
    /// a save payload. The text kind already shows its title in the
    /// content view, so the title line is omitted there.
    @ViewBuilder
    private func redditFooter(_ post: RedditStoryPost) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if post.kind != .text,
                let title = post.title, !title.isEmpty
            {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
            }
            HStack(spacing: 8) {
                // Checked before it reaches the system opener: this
                // string comes off the daemon, and the label beside it
                // is computed from a different field, so an unchecked
                // one renders "View on Reddit" over anything at all.
                if let url = SafeExternalURL.from(post.permalink) {
                    Link(destination: url) {
                        HStack(spacing: 5) {
                            Text(sourceCtaLabel(for: post.domain))
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.bingeLike.opacity(0.5))
                        )
                        .overlay(
                            Capsule().stroke(
                                Color.bingeLike.opacity(0.7),
                                lineWidth: 1
                            )
                        )
                    }
                }
                if post.save != nil {
                    saveButton(post)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
    }

    /// "View on Reddit" / "View on X" / "Open on PornHub" — keyed off
    /// the post's domain (matches the web StoryViewer's CTA labels).
    private func sourceCtaLabel(for domain: String?) -> String {
        switch (domain ?? "").lowercased() {
        case "x.com", "twitter.com": return "View on X"
        case "pornhub.com": return "Open on PornHub"
        default: return "View on Reddit"
        }
    }

    /// Save-to-Stash button — downloads + adds the post to the
    /// library via binge-server. Tapping pauses auto-advance so the
    /// result (a few seconds for a video) has time to land. Idle →
    /// "Save"; in-flight → spinner; done → "Saved"; error → message.
    @ViewBuilder
    private func saveButton(_ post: RedditStoryPost) -> some View {
        switch currentSaveState {
        case .saved:
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("Saved")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.green)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color.white.opacity(0.10)))
        case .failed(let msg):
            Button { Task { await doSave(post) } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Retry")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.red.opacity(0.45)))
            }
            .help(msg)
        default:
            Button {
                // Pause auto-advance so the save result can render.
                player?.pause()
                stashDBTimer?.cancel()
                capTimer?.cancel()
                Task { await doSave(post) }
            } label: {
                HStack(spacing: 5) {
                    if currentSaveState == .saving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(
                        currentSaveState == .saving
                            ? "Saving…"
                            : currentSaveState == .saved
                                ? "Saved"
                                : "Save to Stash"
                    )
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1)
                )
            }
            .disabled(
                currentSaveState == .saving || currentSaveState == .saved
            )
        }
    }

    /// Build the save request from the current story's performer +
    /// the post's save payload, fire it, and reflect the outcome.
    private func doSave(_ post: RedditStoryPost) async {
        guard let payload = post.save,
            let source = BingeServerService.SaveSource(
                rawValue: payload.source
            ),
            let performerId = currentStory?.performer.id
        else {
            setSaveState(.failed("Not saveable"))
            return
        }
        setSaveState(.saving)
        let req = BingeServerService.SaveToStashRequest(
            performerStashId: performerId,
            source: source,
            handle: payload.handle,
            id: payload.id,
            mediaUrl: payload.mediaUrl,
            kind: payload.kind,
            sourceUrl: post.permalink,
            text: post.title,
            createdUtc: post.createdUtc
        )
        let result = await BingeServerService.saveToStash(req)
        switch result {
        case .ok:
            setSaveState(.saved)
        case .failure(let msg):
            setSaveState(.failed(msg))
        }
    }

    /// Library footer — title (optional) + "Watch full scene"
    /// CTA. Tapping the CTA hands the scene + the story's library
    /// queue back to HomeView via `onWatchFullScene`, which pins
    /// the reel and switches tabs. Mirrors web's library handleCta.
    @ViewBuilder
    private func libraryFooter(_ scene: BingeScene) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = scene.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(
                        color: .black.opacity(0.6),
                        radius: 4, x: 0, y: 1
                    )
            }
            Button {
                let queue = currentStory?.scenes.compactMap {
                    if case .library(let s) = $0 { return s }
                    return nil
                } ?? [scene]
                onWatchFullScene?(scene, queue)
                dismiss()
            } label: {
                HStack(spacing: 5) {
                    Text("Watch full scene")
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.bingeLike.opacity(0.5))
                )
                .overlay(
                    Capsule().stroke(
                        Color.bingeLike.opacity(0.7),
                        lineWidth: 1
                    )
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }

    @ViewBuilder
    private func stashDBFooter(_ sb: StashDBStoryScene) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = sb.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
            }
            if let url = SafeExternalURL.from(sb.stashboxUrl) {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text("View on StashDB")
                            .font(.system(size: 13, weight: .semibold))
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule().fill(Color.bingeLike.opacity(0.5))
                    )
                    .overlay(
                        Capsule().stroke(
                            Color.bingeLike.opacity(0.7),
                            lineWidth: 1
                        )
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }

    // MARK: - Header

    @ViewBuilder
    private func header(for story: Story) -> some View {
        HStack(spacing: 10) {
            // Avatar + name are one tap target — opens the
            // performer's profile via a stacked fullScreenCover.
            // The story's player pauses while the profile is up
            // (see .onChange below).
            Button {
                presentedPerformerId = story.performer.id
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(Color.gray.opacity(0.3))
                        if let p = story.performer.imagePath,
                            let url = URL(string: absolute(p))
                        {
                            AuthImageView(
                                url: url,
                                apiKey: apiKey,
                                contentMode: .fill,
                                maxPixel: 256
                            )
                            .clipShape(Circle())
                        }
                    }
                    .frame(width: 28, height: 28)
                    // HStack(.firstTextBaseline) keeps the badge
                    // sitting on the name's baseline; the badge
                    // overrides the baseline guide internally so
                    // its cap-height aligns with text. Every
                    // story is for a library performer (stories
                    // bucket on localId) — colour swaps on the
                    // favourite flag.
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(story.performer.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        VerifiedBadge(
                            favorite: story.performer.favorite,
                            size: 11
                        )
                        .padding(.leading, 3)
                        if let eff = currentScene?.effectiveAt,
                            !eff.isEmpty
                        {
                            let ago = RelativeDate.relative(eff)
                            if !ago.isEmpty {
                                Text(ago)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(
                                        Color.white.opacity(0.7)
                                    )
                                    .padding(.leading, 8)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5), in: Circle())
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    // MARK: - Navigation

    private func goNext() {
        guard let s = currentStory else { return }
        if sceneIndex < s.scenes.count - 1 {
            sceneIndex += 1
        } else if storyIndex < stories.count - 1 {
            storyIndex += 1
        } else {
            dismiss()
        }
    }

    private func goPrev() {
        if sceneIndex > 0 {
            sceneIndex -= 1
        } else if storyIndex > 0 {
            // Land on the previous performer's LAST scene, not their
            // first. Stepping back across a seam and being dropped at
            // the top of a thirty-scene strip means thirty more taps to
            // get back to where you were. The web viewer does the same
            // and has a test named for it.
            pendingLastScene = true
            storyIndex -= 1
        }
    }

    /// Single-fire auto-advance. Every non-user advance (video end,
    /// the video watchdog cap, the image / stashdb timers) routes
    /// through here so a scene can't be skipped by two sources
    /// firing at once. Reset per scene in loadScene().
    private func autoAdvance() {
        guard !didAutoAdvance else { return }
        didAutoAdvance = true
        goNext()
    }

    /// Arm a wall-clock watchdog that auto-advances after `secs` —
    /// the video preview cap and the no-media fallback. Replaces any
    /// existing cap task; cleared in teardown().
    /// Give the watchdog back whatever this slide still had coming.
    private func rearmCapAfterBackground() {
        guard capDuration > 0 else { return }
        let remaining = capDuration * (1 - progress)
        armCap(after: max(0.5, remaining))
    }

    private func armCap(after secs: Double) {
        capDuration = secs
        capTimer?.cancel()
        capTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(secs))
            if !Task.isCancelled { autoAdvance() }
        }
    }

    // MARK: - Load (multi-source)

    private func loadScene() {
        teardown()
        progress = 0
        // A fresh slide starts with no debt.
        backgroundDebt = 0
        leftForegroundAt = nil
        didAutoAdvance = false
        switch currentScene {
        case .library(let scene):
            loadLibrary(scene)
        case .stashDB(let sb):
            loadStashDB(sb)
        case .reddit(let post):
            loadReddit(post)
        case .none:
            // A performer whose posts were all filtered out lands here.
            // Returning left the sheet on a black panel with the
            // previous scene's spinner still turning and nothing that
            // would ever advance or dismiss it. Stop the spinner and
            // move on the way an empty scene otherwise would.
            loading = false
            armCap(after: 1.0)
        }
    }

    /// Library: AVPlayer + preview clip + periodic time observer
    /// for progress + didPlayToEndTime auto-advance.
    private func loadLibrary(_ scene: BingeScene) {
        // Demo: the media is a procedural gradient, not a real video, so
        // didPlayToEndTime never fires. Drive a short timed progress like
        // the StashDB path so the story walks through its scenes.
        if DemoMode.isOn {
            loading = false
            let total = Self.demoStoryDuration
            let start = Date()
            stashDBTimer = Task { @MainActor in
                while !Task.isCancelled {
                    let elapsed =
                    Date().timeIntervalSince(start) - backgroundDebt
                    progress = min(1, elapsed / total)
                    if elapsed >= total { autoAdvance(); return }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            return
        }
        loading = true
        guard
            let url = scene.previewURL(base: baseURL)
                ?? scene.streamURL(base: baseURL)
        else {
            // No preview and no stream — nothing to play. Clear the
            // spinner and advance after a brief beat rather than
            // hanging on the spinner forever.
            loading = false
            armCap(after: Self.noMediaCapDuration)
            return
        }
        let asset = AVURLAsset(
            url: url,
            options: CredentialSession.assetOptions(for: url, apiKey: apiKey)
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        let p = AVPlayer(playerItem: item)
        p.isMuted = muted
        p.automaticallyWaitsToMinimizeStalling = false
        player = p
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in autoAdvance() }
        }
        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 15),
            queue: .main
        ) { time in
            if loading && time.seconds > 0 { loading = false }
            let dur = item.duration.seconds
            guard dur.isFinite, dur > 0 else { return }
            progress = min(1, time.seconds / dur)
        }
        p.play()
        // Watchdog: cap the preview and guarantee auto-advance even
        // if playback never begins (dead/slow stream) or runs long.
        armCap(after: Self.videoCapDuration)
    }

    /// Reddit: kind drives the loader.
    /// - video: AVPlayer + didPlayToEndTime auto-advance, no
    ///          ApiKey header (reddit / redgifs are public).
    /// - image / text / link: 5s timer auto-advance.
    private func loadReddit(_ post: RedditStoryPost) {
        if post.kind == .video, let url = post.mediaUrl
            .flatMap(URL.init(string:))
        {
            loading = true
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 2
            let p = AVPlayer(playerItem: item)
            p.isMuted = muted
            p.automaticallyWaitsToMinimizeStalling = false
            player = p
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { _ in
                Task { @MainActor in autoAdvance() }
            }
            timeObserver = p.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 15),
                queue: .main
            ) { time in
                if loading && time.seconds > 0 { loading = false }
                let dur = item.duration.seconds
                guard dur.isFinite, dur > 0 else { return }
                progress = min(1, time.seconds / dur)
            }
            p.play()
            // Watchdog cap — same as the library preview path.
            armCap(after: Self.videoCapDuration)
            return
        }
        // image / text / link → fixed-duration timer.
        loading = false
        let total = Self.redditTimedDuration
        let start = Date()
        stashDBTimer = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed =
                    Date().timeIntervalSince(start) - backgroundDebt
                progress = min(1, elapsed / total)
                if elapsed >= total {
                    autoAdvance()
                    return
                }
                try? await Task.sleep(for: .milliseconds(67))
            }
        }
    }

    /// StashDB: cover image + timer-driven 5s progress + auto-
    /// advance. No AVPlayer, no audio.
    private func loadStashDB(_ sb: StashDBStoryScene) {
        // Image-only — no buffer phase; treat as instantly ready
        // so the spinner doesn't linger over a perfectly-rendered
        // cover.
        loading = false
        let total = Self.stashDBDuration
        let start = Date()
        stashDBTimer = Task { @MainActor in
            while !Task.isCancelled {
                let elapsed =
                    Date().timeIntervalSince(start) - backgroundDebt
                progress = min(1, elapsed / total)
                if elapsed >= total {
                    autoAdvance()
                    return
                }
                try? await Task.sleep(for: .milliseconds(67))
            }
        }
    }

    private func teardown() {
        if let t = timeObserver, let p = player {
            p.removeTimeObserver(t)
        }
        timeObserver = nil
        if let e = endObserver {
            NotificationCenter.default.removeObserver(e)
        }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        stashDBTimer?.cancel()
        stashDBTimer = nil
        capTimer?.cancel()
        capTimer = nil
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        let trimmed = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return "\(trimmed)\(path)"
    }
}
