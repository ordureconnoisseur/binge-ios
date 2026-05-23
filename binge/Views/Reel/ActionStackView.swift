import SwiftUI

// Right-rail action stack on every reel slide. v0.1 ships just the
// heart (likes/o-counter); rate / multiview / save land in v0.2.
//
// Display logic mirrors the web plugin: the count hides when the
// scene's o-counter is 0 to keep the rail visually quiet for new
// scenes that haven't accumulated activity yet.
struct ActionStackView: View {
    let oCounter: Int
    let isAnimating: Bool
    let onLike: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Button(action: onLike) {
                VStack(spacing: 2) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.white)
                        .scaleEffect(isAnimating ? 1.25 : 1.0)
                        .animation(
                            .spring(response: 0.25, dampingFraction: 0.55),
                            value: isAnimating
                        )
                    if oCounter > 0 {
                        Text("\(oCounter)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 2)
        .padding(.trailing, 12)
        .padding(.bottom, 90)
    }
}
