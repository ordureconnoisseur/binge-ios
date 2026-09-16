import AVKit
import SwiftUI

// UIViewRepresentable wrapper around AVPlayerLayer. SwiftUI's native
// VideoPlayer ships a full AVPlayerViewController — controls, AirPlay
// button, full chrome — none of which we want in a reel slide. The
// AVPlayerLayer-in-a-plain-UIView pattern lets us own playback +
// gesture handling entirely.
//
// Players are pooled (see PlayerPool, a capacity-3 LRU of
// AVQueuePlayer + AVPlayerLooper) and handed to this view per slide;
// this wrapper just hosts whichever AVPlayer it's given. SceneSlideView
// drives attach/detach + the showcase-blur frost below.
struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    /// Reel only. How far the screen continues below this view, in
    /// points; the reflection runs to the screen edge, not to the
    /// view's edge. nil, the default, draws no reflection, which is
    /// what the feed card, story viewer and scene sheet want.
    var reflectsBelow: CGFloat? = nil
    /// Aspect-fit by default. The reel passes aspect-fill for Crop to
    /// fit; see SceneSlideView.
    var gravity: AVLayerVideoGravity = .resizeAspect
    // Showcase mode — frost the live video for safe capture. @AppStorage
    // makes SwiftUI re-run updateUIView when the setting flips. All four
    // video surfaces (reel, feed card, story viewer, scene sheet) reuse
    // this view, so the one hook covers them all.
    @AppStorage("binge.showcaseBlur") private var showcaseBlur = false

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        // Aspect-fit (letterbox), NOT aspect-fill (crop). When a
        // landscape (16:9) video plays in a portrait (9:16) slide,
        // .resizeAspectFill would crop the sides to fill the slide
        // vertically — losing actual video content. .resizeAspect
        // shows the whole frame and pads with black above/below.
        // The slide's own black background fills the leftover area,
        // producing clean letterbox bars rather than the next
        // slide's frame bleeding to the edges of the visible video.
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .black
        view.reflectsBelow = reflectsBelow
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
            uiView.setNeedsLayout()
        }
        uiView.reflectsBelow = reflectsBelow
        uiView.setShowcaseBlurred(showcaseBlur)
    }
}

// The frost under the reel's scrub bar.
//
// Not a SwiftUI material. .ultraThinMaterial is the lightest one
// there is and it was still too much: it blurs at the full system
// radius, and its tint lifts a black frame to grey, so on a dark
// scene the strip below the scrub bar lit up. Neither is adjustable
// on a Material. This is the same construction as the showcase blur
// above, a UIVisualEffectView held partway through its animation so
// the blur is a fraction of the system radius, in the dark variant,
// with a black veil so black stays black and colour underneath is
// dimmed rather than brightened. The two numbers are the whole
// design and live here so they can be tuned in one place.
struct ReelFrost: UIViewRepresentable {
    /// Share of the system blur radius. 1 is the full ultra-thin blur.
    var strength: CGFloat = 0.45
    /// Black laid over the blur, 0 to 1.
    var veil: CGFloat = 0.32

    func makeUIView(context: Context) -> FrostUIView {
        let view = FrostUIView()
        view.apply(strength: strength, veil: veil)
        return view
    }

    func updateUIView(_ uiView: FrostUIView, context: Context) {
        uiView.apply(strength: strength, veil: veil)
    }
}

final class FrostUIView: UIView {
    private let effectView = UIVisualEffectView(effect: nil)
    private let veilView = UIView()
    private var animator: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        effectView.frame = bounds
        effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(effectView)
        veilView.frame = bounds
        veilView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        veilView.backgroundColor = .black
        addSubview(veilView)
    }

    required init?(coder: NSCoder) { nil }

    func apply(strength: CGFloat, veil: CGFloat) {
        if animator == nil {
            let a = UIViewPropertyAnimator(duration: 1, curve: .linear) {
                [effectView] in
                effectView.effect = UIBlurEffect(
                    style: .systemUltraThinMaterialDark
                )
            }
            a.pausesOnCompletion = true
            animator = a
        }
        animator?.fractionComplete = min(max(strength, 0.01), 1)
        veilView.alpha = min(max(veil, 0), 1)
    }

    deinit {
        // See PlayerUIView.deinit: a paused animator throws on release.
        if let a = animator {
            switch a.state {
            case .active: a.stopAnimation(true)
            case .stopped: a.finishAnimation(at: .current)
            case .inactive: break
            @unknown default: break
            }
        }
    }
}

// Tiny UIView subclass whose backing layer is an AVPlayerLayer.
// Standard pattern — overriding `layerClass` is what AVKit's own
// AVPlayerView does, and it's the cleanest way to keep the player
// layer auto-sized to the view's bounds via Auto Layout.
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    // The reflection under the picture.
    //
    // A portrait picture on this phone ends about 77pt short of the
    // screen edge, just under the scrub bar, and that strip was bare
    // black under the floating nav. When the picture ends after the
    // scrub bar and before the screen edge, its bottom is appended
    // vertically mirrored so the picture runs to the edge as a
    // reflection; the frost in SceneSlideView then lies over both.
    //
    // A second AVPlayerLayer on the SAME player, not a second player:
    // the pool's whole point is that each slide costs one decoder.
    // Where the picture sits comes from the main layer's own videoRect,
    // which already accounts for the file's rotation and the gravity,
    // so the seam at the picture's bottom edge is continuous.
    var reflectsBelow: CGFloat? {
        didSet {
            if reflectsBelow == nil { tearDownMirror() }
            setNeedsLayout()
        }
    }
    private var mirrorClip: CALayer?
    private var mirrorLayer: AVPlayerLayer?
    private var videoRectObservation: NSKeyValueObservation?

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutMirror()
    }

    private func tearDownMirror() {
        videoRectObservation = nil
        mirrorClip?.removeFromSuperlayer()
        mirrorClip = nil
        mirrorLayer = nil
    }

    private func layoutMirror() {
        guard let bleed = reflectsBelow else { return }
        let rect = playerLayer.videoRect
        let H = bounds.height
        let W = bounds.width
        // The picture's visible bottom edge. Under aspect-fill the
        // videoRect runs past the layer, which clips it, so the edge
        // that matters is the layer's own.
        let pictureBottom = min(rect.maxY, H)
        // Distance from that edge to the screen edge, and the strip
        // the scrub bar leaves below itself.
        let gap = (H + bleed) - pictureBottom
        let band =
            BingeBottomNav.scrubClearance
            + (window?.safeAreaInsets.bottom ?? 0)
        guard rect.width > 0, gap > 0.5, gap <= band + 0.5, W > 0 else {
            mirrorClip?.isHidden = true
            return
        }
        if mirrorClip == nil {
            let clip = CALayer()
            clip.masksToBounds = true
            let mirror = AVPlayerLayer()
            mirror.videoGravity = .resizeAspect
            // Flipped about its own centre. position is the centre in
            // the clip's coordinates and is not affected by the flip.
            mirror.transform = CATransform3DMakeScale(1, -1, 1)
            clip.addSublayer(mirror)
            layer.addSublayer(clip)
            mirrorClip = clip
            mirrorLayer = mirror
            // The picture's rect changes when the item becomes ready
            // and when the stream is swapped for the HEVC fallback.
            videoRectObservation = playerLayer.observe(\.videoRect) {
                [weak self] _, _ in
                DispatchQueue.main.async { self?.layoutMirror() }
            }
        }
        guard let clip = mirrorClip, let mirror = mirrorLayer else { return }
        if mirror.player !== playerLayer.player {
            mirror.player = playerLayer.player
        }
        if mirror.videoGravity != playerLayer.videoGravity {
            mirror.videoGravity = playerLayer.videoGravity
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.isHidden = false
        clip.frame = CGRect(x: 0, y: rect.maxY, width: W, height: gap)
        // Same size as the main layer, so the picture lands in the same
        // place, then slid up so the flipped picture's top edge meets
        // the clip's top edge: the picture's bottom row is the first
        // row of the reflection.
        mirror.bounds = CGRect(x: 0, y: 0, width: W, height: H)
        mirror.position = CGPoint(x: W / 2, y: pictureBottom - H / 2)
        CATransaction.commit()
    }

    // Showcase-mode blur: a UIVisualEffectView laid over the player
    // layer, sampling the live AVPlayerLayer as its backdrop (the render
    // server composites it) — smooth, no per-frame CIFilter cost, only
    // while capture mode is on. `.systemUltraThinMaterial` keeps the
    // colour tint to a minimum (vs the old dark thick frost), and a
    // paused UIViewPropertyAnimator holds the effect at partial strength
    // (`blurFraction`) so the blur is softer than a full system blur.
    private var blurOverlay: UIVisualEffectView?
    private var blurAnimator: UIViewPropertyAnimator?
    private let blurFraction: CGFloat = 0.55

    func setShowcaseBlurred(_ on: Bool) {
        guard on else {
            blurOverlay?.isHidden = true
            return
        }
        if blurOverlay == nil {
            let overlay = UIVisualEffectView(effect: nil)
            overlay.frame = bounds
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            overlay.isUserInteractionEnabled = false
            addSubview(overlay)
            blurOverlay = overlay

            // Scrub a paused animator to a partial fraction = a softer
            // blur than the full effect, with no colour wash.
            let animator = UIViewPropertyAnimator(
                duration: 1, curve: .linear
            ) {
                overlay.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            }
            animator.pausesOnCompletion = true
            animator.fractionComplete = blurFraction
            blurAnimator = animator
        }
        blurOverlay?.isHidden = false
    }

    deinit {
        videoRectObservation = nil
        // A property animator left paused/active throws when released
        // ("error to release a paused or stopped property animator").
        // Drive it to a releasable state before this view deallocs.
        if let a = blurAnimator {
            switch a.state {
            case .active: a.stopAnimation(true)
            case .stopped: a.finishAnimation(at: .current)
            case .inactive: break
            @unknown default: break
            }
        }
    }
}
