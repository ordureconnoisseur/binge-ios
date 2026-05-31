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
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
        uiView.setShowcaseBlurred(showcaseBlur)
    }
}

// Tiny UIView subclass whose backing layer is an AVPlayerLayer.
// Standard pattern — overriding `layerClass` is what AVKit's own
// AVPlayerView does, and it's the cleanest way to keep the player
// layer auto-sized to the view's bounds via Auto Layout.
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

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
