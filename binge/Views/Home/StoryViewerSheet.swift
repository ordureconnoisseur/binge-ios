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
    @AppStorage("binge.muted") private var muted: Bool = true

    @State private var storyIndex: Int
    @State private var sceneIndex: Int = 0
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
    @State private var tour = TourDirector.shared

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
                    .padding(.top, 6)
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
        .statusBarHidden(tour.isRunning)
        .onChange(of: storyIndex) { _, _ in
            sceneIndex = 0
            loadScene()
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
        case .library:
            if let player {
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

    /// Reddit footer — title (for media kinds where the caption
    /// would otherwise be invisible) + "View on Reddit" CTA. The
    /// text kind already shows its title in the content view, so
    /// the title line is omitted there to avoid duplication.
    @ViewBuilder
    private func redditFooter(_ post: RedditStoryPost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if post.kind != .text,
                let title = post.title, !title.isEmpty
            {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 1)
            }
            if let url = URL(string: post.permalink) {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text("View on Reddit")
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
        .padding(.bottom, 28)
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
            if let url = URL(string: sb.stashboxUrl) {
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
            // Mute toggle only visible when on a library scene —
            // stashdb scenes have no audio.
            if case .library = currentScene {
                Button {
                    muted.toggle()
                    player?.isMuted = muted
                } label: {
                    Image(
                        systemName: muted
                            ? "speaker.slash.fill"
                            : "speaker.wave.2.fill"
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5), in: Circle())
                }
            }
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
    private func armCap(after secs: Double) {
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
        didAutoAdvance = false
        switch currentScene {
        case .library(let scene):
            loadLibrary(scene)
        case .stashDB(let sb):
            loadStashDB(sb)
        case .reddit(let post):
            loadReddit(post)
        case .none:
            return
        }
    }

    /// Library: AVPlayer + preview clip + periodic time observer
    /// for progress + didPlayToEndTime auto-advance.
    private func loadLibrary(_ scene: BingeScene) {
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
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["ApiKey": apiKey]
            ]
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
                let elapsed = Date().timeIntervalSince(start)
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
                let elapsed = Date().timeIntervalSince(start)
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
