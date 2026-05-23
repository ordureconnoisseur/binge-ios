import AVKit
import SwiftUI

// UIViewRepresentable wrapper around AVPlayerLayer. SwiftUI's native
// VideoPlayer ships a full AVPlayerViewController — controls, AirPlay
// button, full chrome — none of which we want in a reel slide. The
// AVPlayerLayer-in-a-plain-UIView pattern lets us own playback +
// gesture handling entirely.
//
// One AVPlayer per slide; ownership lives in SceneSlideView. We don't
// pool players in v0.1 — iOS handles ~4 concurrent decoders without
// trouble for short loops, and the reel only ever has the active
// slide + 1 prefetched on each side mounted at once via
// TabView(.page).
struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

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
    }
}

// Tiny UIView subclass whose backing layer is an AVPlayerLayer.
// Standard pattern — overriding `layerClass` is what AVKit's own
// AVPlayerView does, and it's the cleanest way to keep the player
// layer auto-sized to the view's bounds via Auto Layout.
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
