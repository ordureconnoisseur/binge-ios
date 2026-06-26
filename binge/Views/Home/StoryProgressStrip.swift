import SwiftUI

// Top progress strip — one segment per scene in the focused
// performer's stories. Filled segments = 100%, current = `progress`
// (0..1), upcoming = 0%. Identical pattern to the web plugin's
// StoryProgressStrip.tsx — kept thin (3pt) to mirror IG.
//
// For very long story sets (e.g. a 221-scene OnlyFans pack on the
// same performer), we cap visible segments to MAX_VISIBLE and
// slide a window around the current index. Without the cap, the
// 3pt inter-segment spacing alone exceeds screen width and the
// whole header layout (close button, mute, name) collapses with
// it.
struct StoryProgressStrip: View {
    let sceneCount: Int
    let currentIndex: Int
    let progress: Double

    /// Max segments rendered at once. Above this we windowize
    /// around `currentIndex`. 30 keeps each segment readable
    /// (~10pt wide on iPhone) while preserving the IG-style
    /// "where am I in this story" affordance.
    private static let maxVisible: Int = 30
    /// Inter-segment spacing.
    private static let spacing: CGFloat = 3
    /// Segment height.
    private static let height: CGFloat = 3

    var body: some View {
        let (start, end) = visibleRange
        let visible = end - start
        GeometryReader { geo in
            let totalSpacing = Self.spacing * CGFloat(max(0, visible - 1))
            let segWidth = max(
                1, (geo.size.width - totalSpacing) / CGFloat(max(1, visible))
            )
            HStack(spacing: Self.spacing) {
                ForEach(start..<end, id: \.self) { i in
                    segment(at: i, width: segWidth)
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
        }
        .frame(height: Self.height)
    }

    @ViewBuilder
    private func segment(at i: Int, width: CGFloat) -> some View {
        let fill: Double =
            i < currentIndex ? 1
            : i == currentIndex ? progress
            : 0
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.3))
            Capsule().fill(.white)
                .frame(width: width * fill)
        }
        .frame(width: width, height: Self.height)
    }

    /// `[start, end)` slice of the segment range to render. Keeps
    /// the active segment roughly centered when windowing kicks
    /// in; clamps so the window stays inside `0..<sceneCount`.
    private var visibleRange: (Int, Int) {
        guard sceneCount > Self.maxVisible else {
            return (0, sceneCount)
        }
        let half = Self.maxVisible / 2
        var start = max(0, currentIndex - half)
        let end = min(sceneCount, start + Self.maxVisible)
        // Shift back if we hit the right edge so we always show
        // exactly maxVisible segments.
        if end - start < Self.maxVisible {
            start = max(0, end - Self.maxVisible)
        }
        return (start, end)
    }
}
