import SwiftUI
import UIKit

/// A press that keeps reporting where the finger goes once it lands.
///
/// SwiftUI could not express this without breaking the reel. A press on
/// its own gives no position, so there is no way to see the pull that
/// latches the speed; adding a DragGesture beside it wins against the
/// scroll view's pan even when declared simultaneous, and the corner
/// stops scrolling at all. Raising the press's own thresholds does not
/// help, because the problem was never how far or how long.
///
/// UIKit's recogniser does both natively. It stays out of the way until
/// the press is satisfied, so a swipe reaches the scroll view untouched,
/// and once it fires it reports every movement until the finger lifts.
/// It also reports `cancelled` and `failed`, not only `ended`, which is
/// what stops the speed sticking on when the gesture dies some way other
/// than a clean lift.
struct HoldAndPull: UIViewRepresentable {
    /// How long the finger must stay down before this counts as a hold.
    var minimumDuration: TimeInterval = 0.45
    /// How far it may stray in that time before this is read as a swipe.
    var allowableMovement: CGFloat = 8
    /// The hold was satisfied.
    var onBegan: () -> Void
    /// Vertical travel since the hold began. Positive is downward.
    var onChanged: (CGFloat) -> Void
    /// The finger lifted, or the gesture was cancelled or failed.
    var onEnded: () -> Void
    /// Double tap in the same area, which would otherwise be swallowed
    /// by this view sitting over the one that handles it.
    var onDoubleTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        // Do not hold touches back from the views underneath: the reel
        // has to keep scrolling normally until the press is satisfied.
        let hold = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleHold(_:))
        )
        hold.minimumPressDuration = minimumDuration
        hold.allowableMovement = allowableMovement
        hold.delaysTouchesBegan = false
        hold.delaysTouchesEnded = false
        hold.cancelsTouchesInView = false
        view.addGestureRecognizer(hold)

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.numberOfTapsRequired = 2
        tap.delaysTouchesBegan = false
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: HoldAndPull
        /// Where the finger was when the hold fired, so travel is
        /// measured from there rather than from touch-down.
        private var origin: CGPoint = .zero

        init(_ parent: HoldAndPull) { self.parent = parent }

        @objc func handleHold(_ g: UILongPressGestureRecognizer) {
            switch g.state {
            case .began:
                origin = g.location(in: g.view)
                parent.onBegan()
            case .changed:
                let p = g.location(in: g.view)
                parent.onChanged(p.y - origin.y)
            case .ended, .cancelled, .failed:
                parent.onEnded()
            default:
                break
            }
        }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard g.state == .recognized else { return }
            parent.onDoubleTap?()
        }
    }
}
