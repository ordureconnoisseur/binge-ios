import SwiftUI

// Horizontal scroller of performer avatars. One bubble per Story.
// Tap → asks the parent (HomeView) to present StoryViewerSheet at
// the bubble's index. We intentionally don't OWN the sheet here so
// HomeView can present it over the entire tab area.
//
// `LazyHStack` mounts only the bubbles within the visible scroll
// window — critical when there are 100+ stories. A plain HStack
// would eagerly create all StoryBubbles AND kick off all their
// AuthImageView fetches at once, allocating tens to hundreds of
// MB of decoded UIImages.
//
// Empty → `EmptyView`, so the divider below the row doesn't show a
// lonely line above the feed when the user has no recent scenes.
struct StoriesRow: View {
    let stories: [Story]
    let onTap: (Int) -> Void

    @State private var tour = TourDirector.shared
    /// Driven only by the walkthrough — nil otherwise, so manual
    /// scrolling is unaffected.
    @State private var scrollX: String?

    var body: some View {
        if stories.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(stories.enumerated()), id: \.element.id) {
                        idx, story in
                        StoryBubble(story: story) { onTap(idx) }
                            .id(story.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollX, anchor: .leading)
            .onChange(of: tour.tick) { _, _ in
                guard case .homeScrollStories = tour.command else { return }
                // Gentle out-and-back so the row visibly scrolls before
                // a story opens.
                let far = stories.count > 5 ? stories[5].id : stories.last?.id
                withAnimation(.easeInOut(duration: 0.9)) { scrollX = far }
                Task {
                    try? await Task.sleep(for: .seconds(1.0))
                    withAnimation(.easeInOut(duration: 0.7)) {
                        scrollX = stories.first?.id
                    }
                }
            }
        }
    }
}
