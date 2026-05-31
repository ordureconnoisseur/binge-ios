import ImageIO
import SwiftUI
import UIKit

// Async image loader that injects the `ApiKey` header AND
// downsamples the decoded image to the target display size.
// SwiftUI's AsyncImage doesn't expose URLRequest customization or
// decode-time downsampling, so we roll our own.
//
// `contentMode` defaults to .fit (letterbox to preserve full
// content). Circular avatars want .fill so the image crops to the
// circle instead of leaving black bars at the edges — pass that
// explicitly.
//
// `maxPixel` is the maximum dimension (in pixels, not points) of
// the decoded image. CGImageSource's thumbnail API decodes
// straight to the requested size, never allocating the full-
// resolution bitmap. A 1920x1080 Stash screenshot would otherwise
// take 8 MB uncompressed per copy; with maxPixel=1200 it drops to
// ~3 MB, and with maxPixel=256 (avatars) to ~260 KB. Critical for
// not OOMing when the feed has 50+ cards + 150 stories bubbles.
//
// Diagnostic prints fire on non-200 status, decode failure, or
// network error so silent black squares stop being a mystery.
struct AuthImageView: View {
    let url: URL
    let apiKey: String
    var contentMode: ContentMode = .fit
    var maxPixel: CGFloat = 1200
    /// Where the image sits inside its frame when it overflows
    /// (`contentMode: .fill` only). Default `.center` matches
    /// SwiftUI's stock behaviour; circle-cropped performer avatars
    /// pass `.top` so the face area stays in frame instead of
    /// getting cropped out of a centered slice.
    var alignment: Alignment = .center

    @State private var image: UIImage?
    @State private var failed: Bool = false
    // Showcase mode — blurs the decoded image (covers, thumbnails, and
    // the avatars AvatarStack renders through here) so the UI can be
    // captured/streamed without exposing library content. Every image in
    // the app funnels through AuthImageView, so this one hook covers them
    // all. Display-only; off by default.
    @AppStorage("binge.showcaseBlur") private var showcaseBlur = false

    var body: some View {
        Group {
            if let image {
                // Color.clear claims the parent's full proposal so
                // .clipped() has a definite frame; the overlay
                // alignment then controls where the (potentially
                // overflowing) image sits before clipping. The
                // older `.frame(maxW/H: .infinity)` + alignment
                // pattern doesn't work for aspect-fill overflow —
                // .frame's alignment only positions UNDERSIZED
                // children, not oversized ones.
                Color.clear
                    .overlay(alignment: alignment) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            // Blur sits INSIDE .clipped() (and any
                            // caller circle-crop), so edges stay clean.
                            .blur(radius: showcaseBlur ? 20 : 0)
                    }
                    .clipped()
            } else if failed {
                ZStack {
                    Color.gray.opacity(0.2)
                    Image(systemName: "photo.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                }
            } else {
                // Transparent placeholder so the parent's own
                // background shows through during load. Call
                // sites that want a black placeholder layer one
                // behind the AuthImageView themselves (e.g.,
                // SceneFeedCard's ZStack { Color.black; AuthImageView }).
                Color.clear
            }
        }
        .task(id: url) {
            failed = false
            var req = URLRequest(url: url)
            if !apiKey.isEmpty {
                req.setValue(apiKey, forHTTPHeaderField: "ApiKey")
            }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    print("[binge] image \(url.absoluteString) status=\(http.statusCode)")
                    await MainActor.run { failed = true }
                    return
                }
                let downsampled = Self.downsample(data: data, maxPixel: maxPixel)
                if let img = downsampled {
                    await MainActor.run { image = img }
                } else {
                    print("[binge] image \(url.absoluteString) decode failed, \(data.count) bytes")
                    await MainActor.run { failed = true }
                }
            } catch {
                print("[binge] image \(url.absoluteString) error: \(error)")
                await MainActor.run { failed = true }
            }
        }
    }

    // CGImageSource thumbnail decoding. Asks ImageIO for an image
    // scaled to `maxPixel` on its longest side. Decodes directly at
    // that size — never allocates the full-resolution bitmap.
    //
    // `kCGImageSourceShouldCacheImmediately` forces decode to
    // happen on this thread (not lazily on first draw), which is
    // what we want because we're already off the main actor.
    private static func downsample(
        data: Data,
        maxPixel: CGFloat
    ) -> UIImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, opts as CFDictionary
            )
        else {
            // Fallback — full-res decode rather than fail entirely.
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
