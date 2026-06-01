import SwiftUI

/// Haptic feedback gated by the user's `binge.hapticsEnabled` setting.
///
/// Use `.bingeHaptic(_:trigger:)` instead of `.sensoryFeedback(_:trigger:)`
/// so every haptic in the app respects the Settings toggle from one place.
/// The closure variant returns `nil` when haptics are off, which fully
/// suppresses the feedback (vs. just not firing). Still honors the
/// device's System Haptics setting on top of this.
private struct BingeHaptic<Trigger: Equatable>: ViewModifier {
    @AppStorage("binge.hapticsEnabled") private var enabled = true
    let feedback: SensoryFeedback
    let trigger: Trigger

    func body(content: Content) -> some View {
        content.sensoryFeedback(trigger: trigger) { _, _ in
            enabled ? feedback : nil
        }
    }
}

extension View {
    func bingeHaptic<Trigger: Equatable>(
        _ feedback: SensoryFeedback,
        trigger: Trigger
    ) -> some View {
        modifier(BingeHaptic(feedback: feedback, trigger: trigger))
    }
}
