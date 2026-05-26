import SwiftUI
import UIKit

/// Tiny UIKit shim that lets us call
/// `.navigationBarBackButtonHidden(true)` on a NavigationStack
/// destination while keeping the interactive edge-swipe pop
/// gesture alive. SwiftUI ties the gesture to the visibility of
/// the back button by default — hide the button and the gesture
/// goes with it.
///
/// The trick: SwiftUI's `NavigationStack` is backed by a UIKit
/// `UINavigationController`. Its `interactivePopGestureRecognizer`
/// only fires when its `delegate` returns true. When the back
/// button is hidden the delegate normally returns false. We grab
/// the controller via a representable view, swap in our own
/// delegate that always returns true, and the gesture works
/// regardless of the back button's visibility.
///
/// Apply as a background view to any destination that uses
/// `.navigationBarBackButtonHidden(true)`:
/// ```swift
/// .background(InteractivePopRecognizer())
/// ```
struct InteractivePopRecognizer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        // Defer to next runloop so the view is attached to its
        // window + has a navigationController reference.
        DispatchQueue.main.async {
            if let nav = vc.navigationController {
                nav.interactivePopGestureRecognizer?
                    .delegate = context.coordinator
            }
        }
        return vc
    }

    func updateUIViewController(
        _ uiViewController: UIViewController,
        context: Context
    ) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate
    {
        func gestureRecognizerShouldBegin(
            _ gestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// System-wide top safe-area inset (status bar / dynamic island
/// area). `GeometryReader.safeAreaInsets.top` collapses to 0 when
/// the parent applies `.ignoresSafeArea(edges: .top)`, so we
/// can't rely on it to position chrome above the status bar in
/// the pushed-reel case. UIKit's window-level inset is stable
/// regardless of the SwiftUI safe-area state.
enum BingeSafeArea {
    static var top: CGFloat {
        let scene = UIApplication.shared.connectedScenes.first(
            where: { $0.activationState == .foregroundActive }
        ) as? UIWindowScene
        return scene?.keyWindow?.safeAreaInsets.top ?? 47
    }
}
