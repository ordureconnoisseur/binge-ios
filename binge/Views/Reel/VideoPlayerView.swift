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
        view.playerLayer.videoGravity = .resizeAspectFill
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
