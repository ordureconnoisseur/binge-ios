import SwiftUI

// Single circular avatar in the stories row. Wrapped in an IG-style
// gradient ring (pink → orange → red). Performer name caption below,
// truncated to one line.
//
// Reads baseURL + apiKey directly from @AppStorage so the bubble can
// be dropped anywhere without needing them passed down. The path-to-
// URL composition is duplicated across a few Home views — small
// enough that a shared helper would be more friction than it's worth.
struct StoryBubble: View {
    let story: Story
    let onTap: () -> Void

    private var apiKey: String { KeychainStore.shared.stashApiKey }
    @AppStorage("binge.stashUrl") private var baseURL: String = ""

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            LinearGradient.bingeStoryRing,
                            lineWidth: 2.5
                        )
                        .frame(width: 72, height: 72)
                    avatar
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                        .overlay(
                            // 2pt black inset carves the gap
                            // between gradient + avatar so the
                            // ring reads as a distinct band, not
                            // a chunky border. Mirrors the
                            // performer-profile story ring's
                            // inset treatment.
                            Circle().stroke(Color.black, lineWidth: 2)
                        )
                }
                Text(story.performer.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 72)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatar: some View {
        if let path = story.performer.imagePath,
           let url = URL(string: absolute(path)) {
            // .fill — crop to the circle instead of letterboxing.
            // Portrait performer photos in a 1:1 frame would
            // otherwise show black bars left/right.
            //
            // maxPixel=256 — bubble draws at 64pt × 3x scale ≈
            // 192px; 256 leaves headroom without burning memory
            // on a full-res 1000+ px portrait.
            AuthImageView(
                url: url,
                apiKey: apiKey,
                contentMode: .fill,
                maxPixel: 256,
                alignment: .top
            )
        } else {
            Circle().fill(Color.gray.opacity(0.4))
                .overlay(
                    Text(String(story.performer.name.prefix(1)))
                        .foregroundStyle(.white)
                )
        }
    }

    private func absolute(_ path: String) -> String {
        if path.hasPrefix("http") { return path }
        let trimmed = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        return "\(trimmed)\(path)"
    }
}
