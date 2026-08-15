import AVKit
import SwiftUI

// One scene rendered IG-style as a vertical card in the home feed.
// Structure:
//   Header (small primary-performer avatar + primary name +
//   relative time)  →  16:9 screenshot  →  caption stack
//   (inline title+description with …more / @co-performer mentions /
//   #tag row with +N more).
//
// Tap the card → SceneVideoSheet (looping preview).
// Tap the title+description row → expand the truncated description
// inline. Tap the tag row → expand the truncated tag list inline.
// SwiftUI hands the most-specific gesture the event, so these inner
// taps don't bubble up to the card's "open sheet" gesture.
//
// Visual treatment matches the web client's card chrome: dark
// gray surface, 14pt corner radius, hairline border, soft drop
// shadow.
struct SceneFeedCard: View {
    let scene: BingeScene
    let baseURL: String
    let apiKey: String
    /// Who StashDB says is in this scene, for scenes with nobody linked
    /// locally. Already gender-filtered by HomeViewModel. Defaulted so
    /// the reel and other call sites stay as they are.
    var matchedPerformers: [MatchedPerformer] = []
    /// What this scene appears to belong to when nobody at all could be
    /// named: its studio, or the folder it was imported into. Better
    /// than "Unknown", and honest about being a guess.
    var impliedSource: String? = nil
    /// True when this scene is back-catalog you just re-added (old
    /// scraped date, recent created_at). Shows a "reposted" glyph and
    /// reads the relative time off the import date, not the old one.
    var isRepost: Bool = false
    // Counter value to display. Owned by HomeViewModel so the
    // increment survives LazyVStack remount when the card scrolls
    // offscreen and back.
    let oCounter: Int
    let onLike: () -> Void
    /// Hold-to-unlike — fires after the user holds the heart
    /// past `heartHoldDuration`. Mirrors the reel rail's gesture
    /// so the UX matches across both surfaces. Optional so older
    /// call sites that don't wire it stay compiling.
    let onUnlike: () -> Void
    let onTap: () -> Void
    let onPerformerTap: (String) -> Void
    /// A StashDB-matched performer, who has no local id to route on.
    let onMatchedPerformerTap: (MatchedPerformer) -> Void

    /// How many performers are named before the row switches to a
    /// count. Two, because the badges do not shrink and a third name
    /// already truncates to an ellipsis on a phone-width card.
    private static let nameLimit = 2
    /// Per-performer story lookup. When a performer on this
    /// scene has a current story, their avatar bubble gets the
    /// gradient ring and tapping it opens the story instead of
    /// routing through the profile / multi-perf picker. Pass the
    /// home tab's full stories list and the card derives the
    /// matches itself.
    let storiesByPerformerId: [String: Story]
    let onStoryTap: (Story) -> Void
    /// True when this card is the one centered in the viewport.
    /// Drives autoplay — only the active card plays, every
    /// other card stays paused with a poster frame. Mirrors
    /// IG's "focused post" pattern.
    let isActive: Bool
    /// "Watch full" CTA — opens the scene full-screen. Parent
    /// wires this to push a SceneVideoSheet via its presented
    /// state; the card stays agnostic.
    let onWatchFull: () -> Void
    /// Tag pill tapped. Parent routes to the For You tab with
    /// an ad-hoc tag filter applied — mirrors the web card's
    /// HashtagRow onTap behaviour.
    let onTagTap: (BingeScene.Tag) -> Void

    @State private var captionExpanded: Bool = false
    @State private var tagsExpanded: Bool = false
    // Drives the SF Symbol bounce on the heart so taps feel
    // responsive even before the mutation lands.
    @State private var likeBounce: Int = 0
    // Hold-to-unlike state on the heart — mirrors the reel
    // rail's pattern. Press starts the hold timer, release
    // before `heartHoldDuration` fires onLike; the timer firing
    // fires onUnlike and flags didUnlike so the release doesn't
    // double-fire.
    @State private var heartHolding: Bool = false
    @State private var heartDidUnlike: Bool = false
    @State private var heartHoldTask: Task<Void, Never>?
    private static let heartHoldDuration: Duration = .milliseconds(1500)
    @State private var rateOpen: Bool = false
    /// Multi-performer picker sheet. Opens when the user taps
    /// any avatar in a scene that has 2+ performers — mirrors
    /// the reel's PerformerRow + web's PerformerSheet pattern.
    @State private var pickerOpen: Bool = false
    /// Save-to-collection sheet, opened from the bookmark
    /// button. Reuses the same SaveToCollectionSheet the reel
    /// rail's bookmark uses.
    @State private var saveOpen: Bool = false
    // Mute functionality removed for now — playback is always unmuted.
    private let muted = false
    /// Card-local AVPlayer for the inline preview. Created on
    /// .onAppear, torn down on .onDisappear so off-screen cards
    /// in the LazyVStack don't keep AVFoundation sessions hot.
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var posterVisible: Bool = true
    @State private var isPlaying: Bool = false
    /// Watches the item so a source that cannot play is noticed rather
    /// than left as a still frame.
    @State private var statusObserver: NSKeyValueObservation?
    /// Set once this scene's preview has proved unplayable, so the
    /// stream is used directly on every later attach instead of
    /// failing over again each time the card scrolls back.
    @State private var previewFailed: Bool = false

    // First N tags shown inline; the rest hide behind "+M more"
    // until the user taps the row. Matches the web's collapsed
    // tag-row default.
    private static let initialTagLimit = 7

    private var primary: BingeScene.Performer? {
        scene.performers.first
    }

    // Everyone other than the primary — these render as "@name"
    // accent-orange mentions below the title. Empty for solo scenes
    // so the row is omitted.
    private var coPerformers: [BingeScene.Performer] {
        scene.performers.count > 1
            ? Array(scene.performers.dropFirst()) : []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)
            screenshot
            actionRow
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 2)
            caption
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 14)
        }
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: 0, y: 4)
        // Only attach the AVPlayer when this card becomes the
        // centered (active) one. Previously every card that
        // mounted built its own AVQueuePlayer + AVPlayerLooper
        // on `.onAppear`, which meant fast scroll = lots of
        // player create/teardown churn = stuttery scroll. Inactive
        // cards now just show the poster image; the player is
        // built lazily when activeId lands on them.
        .onAppear {
            if isActive { attachPlayer() }
        }
        .onDisappear { detachPlayer() }
        .onChange(of: isActive) { _, active in
            if active {
                if player == nil {
                    attachPlayer()
                } else {
                    applyActiveState(true)
                }
            } else {
                // Tear down players on inactive cards to free
                // AVFoundation resources; a freshly-active card
                // re-attaches on the next onChange.
                detachPlayer()
            }
        }
        .sheet(isPresented: $pickerOpen) {
            PerformerPickerSheet(
                performers: scene.performers,
                baseURL: baseURL,
                apiKey: apiKey,
                onPick: { id in onPerformerTap(id) }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $saveOpen) {
            SaveToCollectionSheet(scene: scene)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 10) {
            // Stack ALL library performers as overlapping
            // avatars (web's AvatarStack pattern). The primary
            // gets the IG gradient ring overlaid when they have
            // a recent story, since that's the time-sensitive
            // signal. Tap on the primary's avatar routes to
            // story when present; on any other avatar routes
            // to that performer's profile.
            avatarStackRow
            Button {
                // Same routing rule as the avatar stack —
                // multi-performer scenes open the picker so the
                // user can choose; single-performer jumps to
                // that profile directly.
                if scene.performers.count > 1 {
                    pickerOpen = true
                } else if let id = primary?.id {
                    onPerformerTap(id)
                } else if let matched = matchedPerformers.first,
                    matchedPerformers.count == 1
                {
                    // Names with nobody linked. One matched performer
                    // routes to her StashDB profile; several are
                    // ambiguous, so the tap does nothing rather than
                    // guessing which one the user meant.
                    onMatchedPerformerTap(matched)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    nameRow
                    // Reposts read their relative time off the import
                    // date (createdAt), not the old scraped date —
                    // the repost badge now lives on the avatar.
                    Text(RelativeDate.relative(
                        isRepost
                            ? (scene.createdAt
                                ?? Story.effectiveAt(for: scene))
                            : Story.effectiveAt(for: scene)
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            .buttonStyle(.plain)
            Spacer()
            SceneCardMenu(items: menuItems)
        }
    }

    /// Library scene → only "Open in Stash" is meaningful (the
    /// scene is already in Stash; tapping the menu pops it open
    /// in Safari at the user's Stash UI).
    private var menuItems: [SceneCardMenu.Item] {
        [
            .init(
                label: "Open in Stash",
                systemImage: "arrow.up.right.square",
                sub: "Opens the scene in your Stash UI"
            ) {
                openInStash()
            }
        ]
    }

    private func openInStash() {
        let trimmed = baseURL.trimmingCharacters(
            in: .init(charactersIn: "/")
        )
        guard let url = URL(string: "\(trimmed)/scenes/\(scene.id)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    /// Comma-joined performer names ("Alice, Bob, Carol"). Falls
    /// back to "Unknown" when the scene has no performers (rare
    /// but possible for orphaned scenes).
    private var performerNames: String {
        let names = scene.performers.map(\.name)
        return names.isEmpty ? "Unknown" : names.joined(separator: ", ")
    }

    /// "PrimaryName ✓, OtherName, ThirdName" — the badge slides in
    /// between the primary's name and the rest as a single Text
    /// run, so SwiftUI lays the icon out on the text's cap-height
    /// line (a separate Image in an HStack ends up bottom-aligned
    /// because the text's bounding-box centre sits below its
    /// visual cap-height centre). Every performer in a library
    /// feed scene is in the user's library by definition; badge
    /// colour distinguishes favourited from non-favourited.
    @ViewBuilder
    private var nameRow: some View {
        if scene.performers.isEmpty {
            // Nobody linked locally. The scene only reached the feed at
            // all because StashDB matched it, so StashDB usually knows
            // the cast: name them, and mark them as not in the library
            // rather than as missing.
            if matchedPerformers.isEmpty {
                Text(impliedSource ?? "Unknown")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } else {
                // No badge on these. A library performer carries her
                // verified mark and a StashDB match does not, so the
                // absence is the signal and nothing has to be added to
                // say so. The marker that used to sit here was a
                // question mark whose meaning lived in a web tooltip
                // that a phone has no way to show.
                let visible = Array(matchedPerformers.prefix(Self.nameLimit))
                let overflow = matchedPerformers.count - visible.count
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    ForEach(
                        Array(visible.enumerated()),
                        id: \.element.id
                    ) { idx, p in
                        if idx > 0 {
                            Text(", ")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Text(p.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if overflow > 0 {
                        Text(" +\(overflow)")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            // Per-performer name + badge run. Each performer's
            // verified mark inherits its own favourite/in-library
            // colour so a comma-joined "Alice ✓, Bob ✓, Carol ✓"
            // accurately reflects all three.
            //
            // Only the first few are named. Every badge holds its
            // fixed size while the names are the only part that can
            // give way, so laying out a whole cast squeezed the names
            // to nothing and left a bare line of badges — a fourteen
            // performer scene rendered as fourteen ticks and no words.
            // The avatar stack above already solved this with the same
            // "+N" overflow, so the two now agree.
            let visible = Array(scene.performers.prefix(Self.nameLimit))
            let overflow = scene.performers.count - visible.count
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(
                    Array(visible.enumerated()),
                    id: \.element.id
                ) { idx, p in
                    if idx > 0 {
                        Text(", ")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(p.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    VerifiedBadge(favorite: p.favorite, size: 12)
                        .padding(.leading, 3)
                }
                if overflow > 0 {
                    // Priority so the count keeps its width: it is the
                    // part that says the cast is bigger than what is
                    // shown, and truncating it undoes the whole point.
                    Text(" +\(overflow)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Avatar stack with a per-performer story-ring overlay.
    /// Tap routing:
    /// - performer has a story → open that story (priority,
    ///   time-sensitive content wins)
    /// - else multi-performer scene → picker (so the user can
    ///   choose which profile to open)
    /// - else single-performer scene → that profile
    @ViewBuilder
    private var avatarStackRow: some View {
        if scene.performers.isEmpty {
            // Nobody linked locally, so the library stack has nothing to
            // draw and the card would show names with no faces. StashDB
            // knows who these people are and hosts their images
            // publicly, so the stack is built from the matched cast
            // instead. No API key: these come off StashDB's CDN, not
            // Stash. No story ring either, since a story belongs to a
            // performer in the library and these are not.
            AvatarStack(
                items: matchedPerformers,
                size: 36,
                overlap: 14,
                visibleLimit: 3,
                resolveImage: { perf in
                    guard let raw = perf.image, let url = URL(string: raw)
                    else { return (nil, "") }
                    return (url, "")
                },
                initial: { String($0.name.prefix(1)) },
                onTap: { onMatchedPerformerTap($0) },
                hasStory: { _ in false }
            )
        } else {
            libraryAvatarStackRow
        }
    }

    @ViewBuilder
    private var libraryAvatarStackRow: some View {
        AvatarStack(
            items: scene.performers,
            size: 36,
            overlap: 14,
            visibleLimit: 3,
            resolveImage: { perf in
                guard let path = perf.imagePath,
                    let url = URL(string: absolute(path))
                else { return (nil, apiKey) }
                return (url, apiKey)
            },
            initial: { String($0.name.prefix(1)) },
            onTap: { perf in
                if let s = storiesByPerformerId[perf.id] {
                    onStoryTap(s)
                } else if scene.performers.count > 1 {
                    pickerOpen = true
                } else {
                    onPerformerTap(perf.id)
                }
            },
            hasStory: { perf in
                storiesByPerformerId[perf.id] != nil
            },
            repostBadgeOnPrimary: isRepost
        )
    }

    // MARK: - Screenshot

    @ViewBuilder
    private var screenshot: some View {
        ZStack {
            Color.black
            // Poster — always rendered behind the player so it
            // sits ready as the fallback when no decoded frame
            // has landed yet. Visible whenever posterVisible is
            // true (initial state + during inactive periods).
            if posterVisible,
                let url = scene.screenshotURL(base: baseURL)
            {
                AuthImageView(url: url, apiKey: apiKey)
                    .transition(.opacity)
            }
            // Only mount VideoPlayerView for the centered card.
            // Inactive cards keep their player paused (so
            // re-activation is fast) but don't render the
            // player layer — otherwise the AVPlayerLayer paints
            // a black frame over the poster while the player
            // sits idle, leaving the user looking at a black
            // box instead of the thumbnail.
            if isActive, let player {
                VideoPlayerView(player: player)
            }
            // Big play glyph when the user manually paused (or
            // pre-attach). Hidden during normal autoplay — the
            // moving frames are their own affordance.
            if !isPlaying {
                Image(systemName: "play.fill")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(20)
                    .background(.black.opacity(0.4), in: Circle())
                    .transition(.opacity)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        // Single tap → toggle play/pause inside the card.
        // Double tap → like (reuses the heart's onLike closure
        // so the local oCounter bump + mutation match the
        // action-row button).
        .onTapGesture(count: 2) {
            likeBounce &+= 1
            onLike()
        }
        .onTapGesture(count: 1) {
            togglePlayPause()
        }
        .animation(.easeOut(duration: 0.15), value: isPlaying)
        .animation(.easeOut(duration: 0.2), value: posterVisible)
    }

    // MARK: - Inline player lifecycle

    /// Build the player + looper. Called on .onAppear when the
    /// card scrolls into view. previewURL is the short MP4
    /// Stash generates for scene previews; streamURL is the
    /// fallback (full-length stream) — same picking logic as
    /// SceneVideoSheet.
    ///
    /// Only AUTOPLAYS when isActive; otherwise the player is
    /// ready-but-paused so the next viewport-center swap is
    /// instant.
    private func attachPlayer() {
        if player != nil {
            // Already attached — just reconcile play state to
            // whatever isActive says now (handles the case
            // where the card re-appeared with a flipped active
            // value).
            applyActiveState(isActive)
            return
        }
        // Stash hands back a preview URL for every scene whether or not
        // the preview was ever generated, so previewURL is almost never
        // nil and the ?? below was effectively dead: an ungenerated
        // preview 404s and the card sat on its poster forever. Measured
        // on the maintainer's library, 15% of scenes with performers and
        // 80% of the StashDB-matched ones have no preview file, which is
        // most of a feed that cannot play.
        let preferred = previewFailed ? nil : scene.previewURL(base: baseURL)
        guard let url = preferred ?? scene.streamURL(base: baseURL)
        else { return }
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": ["ApiKey": apiKey]
            ]
        )
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 2
        let q = AVQueuePlayer(playerItem: item)
        q.isMuted = muted
        q.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: q, templateItem: item)
        player = q
        statusObserver = item.observe(\.status) { observed, _ in
            Task { @MainActor in
                switch observed.status {
                case .failed:
                    // The preview is missing. Fall back to the stream,
                    // which is what the card should have been playing
                    // all along for these scenes.
                    guard !previewFailed else { return }
                    previewFailed = true
                    detachPlayer()
                    attachPlayer()
                case .readyToPlay:
                    // Only the centered card mounts a video layer, so
                    // an inactive card keeps its poster or it would
                    // uncover black. Waiting for ready also replaces a
                    // blind 300ms hide that uncovered the poster
                    // whether or not anything had started.
                    guard isActive else { return }
                    // Same brief hold applyActiveState uses, covering
                    // first-frame decode so the poster does not lift
                    // onto a black frame.
                    try? await Task.sleep(for: .milliseconds(300))
                    posterVisible = false
                default:
                    break
                }
            }
        }
        if isActive {
            q.play()
            isPlaying = true
        } else {
            // Pre-mounted but waiting — keep the poster visible
            // and stay paused until scroll centers this card.
            isPlaying = false
        }
    }

    /// React to isActive flipping. Called from .onChange and
    /// from attachPlayer when the player is reused.
    private func applyActiveState(_ active: Bool) {
        guard let player else { return }
        if active {
            player.play()
            isPlaying = true
            // Brief delay before dropping the poster — covers
            // the first-frame decode latency. Without this the
            // newly-mounted VideoPlayerView paints a black
            // frame for ~100ms before the first decoded frame
            // lands, which reads as a flicker.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                posterVisible = false
            }
        } else {
            player.pause()
            isPlaying = false
            // Restore the poster so this card has a thumbnail
            // again next time the user scrolls past — without
            // this it would show a black background once the
            // VideoPlayerView is unmounted.
            posterVisible = true
        }
    }

    private func detachPlayer() {
        statusObserver?.invalidate()
        statusObserver = nil
        player?.pause()
        looper = nil
        player?.removeAllItems()
        player = nil
        // Re-show the poster so the next attach has something
        // to render under the black background.
        posterVisible = true
        isPlaying = false
    }

    private func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    // MARK: - Caption stack

    @ViewBuilder
    private var caption: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleAndDescription
            // Library scenes don't need a separate @mention row —
            // every performer attached to a library scene is by
            // definition in the library, so they all live in the
            // AvatarStack at the top instead.
            if !scene.tags.isEmpty {
                tagRow
            }
        }
    }

    // Title + description as one inline run. Title is semibold
    // white; description is regular white-85%. Sized per-segment so
    // SwiftUI Text concatenation keeps both their fonts when
    // rendered together (the outer .font modifier we'd otherwise
    // apply would override per-segment fonts — we deliberately
    // don't apply one here).
    //
    // Collapsed → 1 line, "…more" suffix. Expanded → full text,
    // tap to collapse. If a scene has only a title (no details),
    // we show it as a standalone semibold line with 2-line max —
    // there's nothing to expand into.
    @ViewBuilder
    private var titleAndDescription: some View {
        let title = scene.title?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let details = scene.details?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if title.isEmpty && details.isEmpty {
            EmptyView()
        } else if details.isEmpty {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            expandableTitleRow(title: title, details: details)
        }
    }

    @ViewBuilder
    private func expandableTitleRow(
        title: String,
        details: String
    ) -> some View {
        // Multi-style title + details via Text interpolation with
        // embedded Text pieces — replaces the deprecated `Text +`
        // concat. Each piece keeps its own font weight and
        // foregroundColor; the parent Text supplies layout.
        let titleText: Text = title.isEmpty
            ? Text("")
            : Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
        let separator: Text = title.isEmpty ? Text("") : Text(" ")
        let bodyText: Text = Text(details)
            .font(.system(size: 14))
            .foregroundColor(.white.opacity(0.85))
        let combined = Text("\(titleText)\(separator)\(bodyText)")

        if captionExpanded {
            combined
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.15)) {
                        captionExpanded = false
                    }
                }
        } else {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                combined
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("…more")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) {
                    captionExpanded = true
                }
            }
        }
    }

    // Tag row. Each tag is its own Button so the user can tap a
    // single tag to filter the For You reel by it — mirrors the
    // web card's HashtagRow. Tags wrap to multiple lines via
    // FlowLayout. Collapsed shows the first N + a "+M more" pill
    // that expands the row in place.
    @ViewBuilder
    private var tagRow: some View {
        let allTags = scene.tags
        let limit = Self.initialTagLimit
        let remaining = max(0, allTags.count - limit)
        let visible: [BingeScene.Tag] = tagsExpanded || remaining == 0
            ? allTags
            : Array(allTags.prefix(limit))

        FlowLayout(spacing: 4) {
            ForEach(visible, id: \.id) { tag in
                Button {
                    onTagTap(tag)
                } label: {
                    Text("#\(tag.name)")
                        .font(.system(size: 12))
                        .foregroundColor(Color.bingeLink)
                }
                .buttonStyle(.plain)
            }
            if !tagsExpanded && remaining > 0 {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        tagsExpanded = true
                    }
                } label: {
                    Text("+\(remaining) more")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Action row
    //
    // Mirrors the web card's action row: like / rate / multiview /
    // bookmark on the left, "Watch full scene →" right-aligned.
    // Only the heart is functional in v0.2 (calls sceneIncrementO,
    // same mutation the reel uses for double-tap-to-like). The
    // others are intentional placeholders so the visual shape is
    // settled before we wire each behavior.
    //
    // Buttons consume their own tap so the card's outer "open
    // sheet" gesture doesn't also fire. The cosmetic ones do
    // nothing on press but still play SwiftUI's default Button
    // press affordance — feels like a real button, just no-op
    // until later.
    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 18) {
            likeButton
            rateButton
            // Multiview: tap toggles this scene in the queue read by
            // the Multiview player + multiview-ios. Gated on the plugin.
            if PluginContext.shared.hasPlugin(PluginID.multiView) {
                multiviewButton
            }
            if PluginContext.shared.hasPlugin(PluginID.scribe) {
                scribeButton
            }
            bookmarkButton
            Spacer()
            watchFullButton
        }
        .task { await MultiviewQueueStore.shared.refresh() }
        .sheet(isPresented: $rateOpen) {
            // Branch on plugin availability so users without
            // the advancedRating plugin still get the native
            // Stash 5-star rating instead of a dead button.
            if PluginContext.shared.hasAdvancedRating {
                CriterionRatingModal(target: .scene(id: scene.id))
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            } else {
                BasicRatingModal(target: .scene(id: scene.id))
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// ★ that opens the rating sheet — criterion modal when the
    /// advancedRating plugin is installed, the basic Stash
    /// rating modal otherwise. Always enabled (Stash's native
    /// rating works without any plugin).
    @ViewBuilder
    private var rateButton: some View {
        Button {
            rateOpen = true
        } label: {
            BingeIcon(
                glyph: .star(filled: false),
                size: 22,
                color: .white
            )
        }
        .buttonStyle(.plain)
    }

    /// Grid (Multiview) button — toggles this scene in the Multiview
    /// queue. Fills pink while queued; tap optimistically flips it.
    @ViewBuilder
    private var multiviewButton: some View {
        let queued = MultiviewQueueStore.shared.isQueued(scene.id)
        Button {
            Task { await MultiviewQueueStore.shared.toggle(scene.id) }
        } label: {
            BingeIcon(
                glyph: .grid(filled: queued),
                size: 22,
                color: queued ? Color.bingeLike : .white
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Comment-bubble (Scribe) button — opens the scene's Stash
    /// page in Safari. The stashScribe plugin mounts a review
    /// modal there once the page loads.
    @ViewBuilder
    private var scribeButton: some View {
        Button {
            ScribeContext.shared.openScene(scene.id)
        } label: {
            BingeIcon(
                glyph: .pencil, size: 22, color: .white
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var likeButton: some View {
        let active = oCounter > 0
        HStack(spacing: 6) {
            BingeIcon(
                glyph: .heart(filled: active),
                size: 24,
                color: active ? Color.bingeLike : .white
            )
            .shadow(
                color: active
                    ? Color.bingeLike.opacity(0.85)
                    : .clear,
                radius: 6
            )
            .shadow(
                color: active
                    ? Color.bingeLike.opacity(0.45)
                    : .clear,
                radius: 14
            )
            .keyframeAnimator(
                initialValue: 1.0,
                trigger: likeBounce
            ) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(1.25, duration: 0.10)
                    CubicKeyframe(1.0, duration: 0.14)
                }
            }
            if oCounter > 0 {
                Text("\(oCounter)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        // Press-and-shrink affordance — same "is-holding" cue the
        // reel rail uses. Tells the user the press registered
        // and they can let go for a like, or keep holding for
        // unlike.
        .scaleEffect(heartHolding ? 0.88 : 1.0)
        .animation(.easeOut(duration: 0.15), value: heartHolding)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !heartHolding {
                        heartHolding = true
                        heartDidUnlike = false
                        heartHoldTask?.cancel()
                        heartHoldTask = Task { @MainActor in
                            try? await Task.sleep(
                                for: Self.heartHoldDuration
                            )
                            if !Task.isCancelled && heartHolding {
                                heartDidUnlike = true
                                onUnlike()
                            }
                        }
                    }
                }
                .onEnded { _ in
                    heartHoldTask?.cancel()
                    let wasUnlike = heartDidUnlike
                    heartHolding = false
                    heartDidUnlike = false
                    if !wasUnlike {
                        likeBounce &+= 1
                        onLike()
                    }
                }
        )
    }

    @ViewBuilder
    private func cosmeticButton(
        _ glyph: BingeIcon.Glyph,
        size: CGFloat
    ) -> some View {
        Button {
            // v0.2 placeholder — visual shape only.
        } label: {
            BingeIcon(glyph: glyph, size: size)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var watchFullButton: some View {
        Button {
            onWatchFull()
        } label: {
            HStack(spacing: 3) {
                Text("Watch full")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Bookmark — opens the Save-to-collection sheet (same one
    /// the reel rail uses). Wraps a real .sheet binding so the
    /// card can host the picker locally; HomeView doesn't need
    /// to know about it.
    @ViewBuilder
    private var bookmarkButton: some View {
        Button {
            saveOpen = true
        } label: {
            BingeIcon(
                glyph: .bookmark(filled: false),
                size: 22,
                color: .white
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        let trimmed = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return "\(trimmed)\(path)"
    }
}
