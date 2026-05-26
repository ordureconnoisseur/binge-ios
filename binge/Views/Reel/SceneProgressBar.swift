import AVFoundation
import SwiftUI
import UIKit

// Bottom seek bar. Drag-to-scrub with a floating thumbnail preview
// above the drag position — IG Reels pattern. Edge-to-edge layout
// (no horizontal padding) so it reads as part of the chrome rather
// than a floating element.
//
// The bar height grows on drag (3pt → 5pt) so the active scrub is
// obvious. The hit area is 20pt tall regardless — fingers don't hit
// 3pt-tall targets reliably.
//
// Thumbnail generation is delegated to the parent via `thumbnailFor`
// so this view stays purely visual. Parent uses
// AVAssetImageGenerator on the current player's asset.
struct SceneProgressBar: View {
    let progress: Double
    let duration: Double?
    // Native aspect of the underlying video (width / height). Sizes
    // the preview rectangle so a 9:16 phone clip renders as a tall
    // portrait thumb, not a stretched 16:9 box. Defaults to 16:9
    // for older library imports where width/height weren't fetched.
    let aspectRatio: CGFloat
    let onSeek: (Double) -> Void
    let onScrubStart: () -> Void
    let onScrubEnd: () -> Void
    let thumbnailFor: (Double) async -> UIImage?

    @State private var isDragging: Bool = false
    @State private var dragRatio: Double = 0
    @State private var previewImage: UIImage?
    // Monotonic counter to scope each thumbnail request to the
    // latest drag position — stale requests get discarded by
    // checking this counter when they finish.
    @State private var thumbRequest: Int = 0

    // Display ratio: drag position while scrubbing, playback
    // progress otherwise. The bar fills to this fraction.
    private var displayRatio: Double {
        isDragging ? dragRatio : progress
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.clear
                bar(width: geo.size.width)
            }
            .frame(width: geo.size.width, height: 20)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: geo.size.width))
            .overlay(alignment: .bottom) {
                if isDragging {
                    preview(barWidth: geo.size.width)
                        .offset(y: -28)
                }
            }
        }
        .frame(height: 20)
    }

    // MARK: - Bar visual

    @ViewBuilder
    private func bar(width: CGFloat) -> some View {
        let fill = max(0, min(1, displayRatio))
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.25))
            Rectangle().fill(Color.white)
                .frame(width: width * fill)
        }
        .frame(height: isDragging ? 5 : 3)
        .animation(.easeOut(duration: 0.12), value: isDragging)
    }

    // MARK: - Preview thumbnail

    // Floats above the bar at the scrub X position. Clamped to
    // stay fully on-screen (no half-off-screen previews near the
    // very ends of the bar). Preview rectangle sized to the
    // video's native aspect: landscape clips render wide-and-short,
    // portrait clips render tall-and-narrow.
    @ViewBuilder
    private func preview(barWidth: CGFloat) -> some View {
        // Bounding box — preview scales to fit while preserving
        // aspect. Both dims capped so a 9:16 portrait clip's
        // preview isn't twice as tall as a 16:9 clip's would be.
        // @ViewBuilder treats if/else statements as branching
        // views — using a ternary keeps these as plain
        // expressions so the closure stays a single view block.
        let maxBoxW: CGFloat = 124
        let maxBoxH: CGFloat = 124
        let aspect = max(0.2, aspectRatio)
        let boxAspect = maxBoxW / maxBoxH
        let widerThanBox = aspect >= boxAspect
        let thumbW: CGFloat = widerThanBox ? maxBoxW : maxBoxH * aspect
        let thumbH: CGFloat = widerThanBox ? maxBoxW / aspect : maxBoxH
        let half = thumbW / 2
        let edgeInset: CGFloat = 10
        let unclamped = dragRatio * barWidth
        let x = min(
            max(half + edgeInset, unclamped),
            barWidth - half - edgeInset
        )
        VStack(spacing: 5) {
            ZStack {
                Color.black
                if let img = previewImage {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ProgressView()
                        .tint(.white.opacity(0.6))
                }
            }
            .frame(width: thumbW, height: thumbH)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 4)
            if let duration {
                Text(formatTime(dragRatio * duration))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        // Anchor center of preview at scrub X. Y offset by the
        // preview's own half-height + a small gap so the bottom
        // edge sits just above the bar regardless of preview size.
        .position(x: x, y: -(thumbH / 2 + 20))
        .allowsHitTesting(false)
    }

    // MARK: - Gesture

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    onScrubStart()
                }
                let ratio = max(0, min(1, value.location.x / width))
                dragRatio = ratio
                requestThumbnail(for: ratio)
            }
            .onEnded { _ in
                onSeek(dragRatio)
                onScrubEnd()
                isDragging = false
                previewImage = nil
            }
    }

    private func requestThumbnail(for ratio: Double) {
        thumbRequest &+= 1
        let token = thumbRequest
        Task {
            let img = await thumbnailFor(ratio)
            // Drop result if a newer drag position has been
            // requested since — prevents flicker as user drags
            // rapidly.
            if token == thumbRequest {
                await MainActor.run { previewImage = img }
            }
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
