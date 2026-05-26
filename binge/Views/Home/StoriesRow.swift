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

    var body: some View {
        if stories.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(stories.enumerated()), id: \.element.id) {
                        idx, story in
                        StoryBubble(story: story) { onTap(idx) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }
}
