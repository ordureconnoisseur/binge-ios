import SwiftUI
import UIKit

/// iOS-style "swipe from the leading edge to dismiss" gesture.
/// Mirrors UINavigationController's interactivePopGestureRecognizer:
/// touch in the leading ~30pt of the SCREEN, drag right, the
/// whole sheet follows your finger; release past the threshold
/// and the content finishes sliding off to the right and
/// `dismiss()` fires.
///
/// `.fullScreenCover` defaults to a slide-DOWN dismissal which
/// reads as a card falling away rather than popping back to the
/// parent screen. By offsetting the content ourselves and then
/// suppressing the cover's own animation (Transaction), the user
/// sees a single continuous slide-off-to-the-right.
///
/// Implementation notes:
/// - Uses `.coordinateSpace: .global` so `startLocation.x` is
///   measured from the actual screen edge, not a parent
///   container's local origin. Without that, NavigationStacks /
///   safe-area insets shift the edge inward.
/// - `highPriorityGesture` so the dismiss wins over any inner
///   ScrollView or button pan recognition.
/// - Screen width pulled from UIScreen rather than wrapping in a
///   GeometryReader, which was changing the content's layout
///   behavior under fullScreenCover and silently absorbing taps
///   in some configurations.
struct SwipeRightToDismiss: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    /// Optional override for the dismissal action. When set, this
    /// fires instead of `@Environment(\.dismiss)` — useful for
    /// views that aren't actually presented (e.g. tab contents
    /// that want a "go back to previous tab" gesture).
    var action: (() -> Void)? = nil

    var edgeWidth: CGFloat = 30
    /// Fraction of screen width the user must drag (or fling
    /// toward) before we commit to dismissal. 1/3 is iOS-system
    /// default for interactive pops.
    var commitFraction: CGFloat = 1.0 / 3.0
    /// Predicted-end horizontal velocity (pts) that triggers
    /// dismissal even if the static translation is below the
    /// commit threshold. Lets a quick flick still close.
    var flingVelocity: CGFloat = 600

    @State private var offset: CGFloat = 0
    @State private var isEdgeDrag: Bool = false
    @State private var screenWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                screenWidth = $0
            }
            .highPriorityGesture(
                DragGesture(
                    minimumDistance: 8,
                    coordinateSpace: .global
                )
                .onChanged { value in
                    if !isEdgeDrag {
                        // First .onChanged of this gesture decides
                        // whether we're tracking. Latch so the user
                        // can drag back inside without losing it.
                        isEdgeDrag = value.startLocation.x < edgeWidth
                    }
                    guard isEdgeDrag else { return }
                    offset = max(0, value.translation.width)
                }
                .onEnded { value in
                    defer { isEdgeDrag = false }
                    guard isEdgeDrag else { return }
                    let velocity =
                        value.predictedEndTranslation.width
                        - value.translation.width
                    let commit =
                        screenWidth * commitFraction
                    let shouldDismiss =
                        value.translation.width >= commit
                        || velocity > flingVelocity
                    if shouldDismiss {
                        withAnimation(.easeOut(duration: 0.22)) {
                            offset = screenWidth
                        }
                        Task { @MainActor in
                            try? await Task.sleep(
                                for: .milliseconds(220)
                            )
                            if let action {
                                action()
                                // Reset for the next presentation
                                // (tab contents stay mounted, so
                                // offset would otherwise persist).
                                offset = 0
                            } else {
                                var txn = Transaction()
                                txn.disablesAnimations = true
                                withTransaction(txn) { dismiss() }
                            }
                        }
                    } else {
                        withAnimation(
                            .spring(
                                response: 0.3,
                                dampingFraction: 0.9
                            )
                        ) { offset = 0 }
                    }
                }
            )
    }
}

extension View {
    /// Attach iOS-style interactive left-edge-swipe-to-dismiss.
    /// Caller is expected to remove redundant toolbar back buttons
    /// so the gesture is the sole dismissal affordance.
    /// Pass `action` to override the default `dismiss()` call —
    /// needed for tab contents that want a back-to-previous-tab
    /// gesture rather than sheet dismissal.
    func swipeRightToDismiss(
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(SwipeRightToDismiss(action: action))
    }
}
