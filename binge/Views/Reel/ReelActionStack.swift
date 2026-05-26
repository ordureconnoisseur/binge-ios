import SwiftUI

// Right-rail action stack for a reel slide. Mirrors the web's
// ActionStack in src/components/ActionStack.tsx — heart / rate /
// multiview / scribe / save / more, vertical, white outlined
// icons with optional count beneath.
//
// Heart is functional (sceneIncrementO mutation). The rest are
// cosmetic v0.2 placeholders — visible so the rail has the right
// silhouette, but tap is a no-op until the underlying features
// land (rating, multiview, scribe, save sheet, more menu).
//
// Subtle drop shadow on every icon so they stay legible over
// busy frames; matches web's text-shadow trick on the same rail.
struct ReelActionStack: View {
    let oCounter: Int
    let onLike: () -> Void
    let onUnlike: () -> Void
    // The "more" (⋯) button is the IG-style guaranteed entry
    // point to scene details — works regardless of whether the
    // scene has a title or description (which the caption row
    // gates on). Wired by SceneSlideView to open the details
    // sheet.
    let onMore: () -> Void
    /// Bookmark — opens the Save-to-collection sheet.
    let onBookmark: () -> Void
    /// Tap on the ★ — opens the criterion-rating sheet (gated on
    /// the advancedRating plugin being installed). nil = star
    /// button stays a no-op cosmetic for callers that haven't
    /// wired the rating sheet yet.
    let onRate: (() -> Void)?
    /// Tap on the comment-bubble glyph — opens the scene's Stash
    /// page in Safari so the stashScribe plugin (which mounts a
    /// review-writing modal inside Stash) takes over. Only shown
    /// when stashScribe is detected by PluginContext.
    let onScribe: (() -> Void)?

    init(
        oCounter: Int,
        onLike: @escaping () -> Void,
        onUnlike: @escaping () -> Void,
        onMore: @escaping () -> Void,
        onBookmark: @escaping () -> Void,
        onRate: (() -> Void)? = nil,
        onScribe: (() -> Void)? = nil
    ) {
        self.oCounter = oCounter
        self.onLike = onLike
        self.onUnlike = onUnlike
        self.onMore = onMore
        self.onBookmark = onBookmark
        self.onRate = onRate
        self.onScribe = onScribe
    }

    @State private var likeBounce: Int = 0
    // Tracks an in-progress hold for the unlike gesture. While
    // pressing the heart and before the 1.5s timer fires, we sit
    // in "holding" — release in that window fires onLike. If the
    // timer fires first, onUnlike runs and didUnlike flips so the
    // subsequent release doesn't double-fire as a like.
    @State private var holding: Bool = false
    @State private var didUnlike: Bool = false
    @State private var holdTask: Task<Void, Never>?

    // Web's HEART_HOLD_DURATION_MS.
    private static let holdDuration: Duration = .milliseconds(1500)

    var body: some View {
        VStack(spacing: 22) {
            heartButton
            rateButton
            // Multiview slot intentionally omitted on mobile —
            // the plugin's grid layout doesn't translate well
            // to a portrait phone screen.
            if PluginContext.shared.hasPlugin(PluginID.scribe)
                && onScribe != nil
            {
                scribeButton
            }
            bookmarkButton
            moreButton
        }
        .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 2)
    }

    @ViewBuilder
    private var scribeButton: some View {
        Button {
            onScribe?()
        } label: {
            BingeIcon(glyph: .pencil, size: 32)
                // Same hit-test fix as bookmark/more — the
                // comment-bubble outline has internal gaps; with-
                // out contentShape most taps fall through.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// ★ on the reel rail. Always tappable — the caller's
    /// sheet branches on `PluginContext.shared.hasAdvancedRating`
    /// to pick between the criterion modal and Stash's basic
    /// 5-star fallback. Falls back to a no-op only when the
    /// caller didn't wire `onRate`.
    @ViewBuilder
    private var rateButton: some View {
        Button {
            onRate?()
        } label: {
            BingeIcon(
                glyph: .star(filled: false),
                size: 32,
                color: onRate == nil ? .white.opacity(0.35) : .white
            )
            // Same hit-test fix as bookmark/more. The star shape
            // has transparent gaps inside its outline — without
            // contentShape, SwiftUI only registers taps on the
            // drawn vector path, so most taps hit the gaps and
            // miss the button entirely.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onRate == nil)
    }

    @ViewBuilder
    private var heartButton: some View {
        let active = oCounter > 0
        VStack(spacing: 3) {
            BingeIcon(
                glyph: .heart(filled: active),
                size: 32,
                color: active ? Color.bingeLike : .white
            )
            // Pink glow when liked — stacked drop-shadows mirror
            // the web's two-pass filter:
            //   drop-shadow(0 0 6px rgba(244,114,182,0.85))
            //   drop-shadow(0 0 14px rgba(244,114,182,0.45))
            .shadow(
                color: active ? Color.bingeLike.opacity(0.85) : .clear,
                radius: 6
            )
            .shadow(
                color: active ? Color.bingeLike.opacity(0.45) : .clear,
                radius: 14
            )
            .keyframeAnimator(
                initialValue: 1.0,
                trigger: likeBounce
            ) { content, scale in
                content.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(1.3, duration: 0.10)
                    CubicKeyframe(1.0, duration: 0.16)
                }
            }
            if oCounter > 0 {
                Text("\(oCounter)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        // While the user holds, the heart shrinks slightly to
        // signal "press registered — keep holding to unlike". Web
        // uses an `is-holding` class for the same affordance.
        .scaleEffect(holding ? 0.88 : 1.0)
        .animation(.easeOut(duration: 0.15), value: holding)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    // First fingerdown frame starts the hold
                    // timer. onChanged fires many times during a
                    // drag — only react to the first.
                    if !holding {
                        holding = true
                        didUnlike = false
                        holdTask?.cancel()
                        holdTask = Task { @MainActor in
                            try? await Task.sleep(
                                for: Self.holdDuration
                            )
                            if !Task.isCancelled && holding {
                                didUnlike = true
                                onUnlike()
                            }
                        }
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel()
                    let wasUnlike = didUnlike
                    holding = false
                    didUnlike = false
                    if !wasUnlike {
                        likeBounce &+= 1
                        onLike()
                    }
                }
        )
    }

    @ViewBuilder
    private func cosmeticButton(_ glyph: BingeIcon.Glyph) -> some View {
        Button {
            // v0.2 placeholder — visual shape only.
        } label: {
            BingeIcon(glyph: glyph, size: 28)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var bookmarkButton: some View {
        Button {
            onBookmark()
        } label: {
            BingeIcon(glyph: .bookmark(filled: false), size: 28)
                // Same hit-test fix as moreButton — Shape labels
                // need contentShape so taps in transparent gaps
                // still register.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var moreButton: some View {
        Button {
            onMore()
        } label: {
            BingeIcon(glyph: .more, size: 28)
                // contentShape forces the entire 28pt frame to be
                // tappable. Without it, the BingeIcon's MoreShape
                // is just three tiny circles + transparent gaps,
                // and SwiftUI's hit test on a plain Button only
                // registers on the drawn parts → most taps miss.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
