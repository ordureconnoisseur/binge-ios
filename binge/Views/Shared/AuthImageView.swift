import SwiftUI
import UIKit

// Async image loader that injects the `ApiKey` header. SwiftUI's
// AsyncImage doesn't expose URLRequest customization, so a
// minimum-viable replacement is needed for any image that lives
// behind Stash's auth.
//
// Used by SceneSlideView to render scene screenshots as a poster
// behind the AVPlayer layer during cold loads. The image fills its
// container with .scaledToFit so 16:9 covers (typical for Stash
// screenshots) letterbox cleanly within the 9:16 slide frame.
struct AuthImageView: View {
    let url: URL
    let apiKey: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.black
            }
        }
        .task(id: url) {
            var req = URLRequest(url: url)
            if !apiKey.isEmpty {
                req.setValue(apiKey, forHTTPHeaderField: "ApiKey")
            }
            if let (data, _) = try? await URLSession.shared.data(for: req),
                let img = UIImage(data: data) {
                await MainActor.run { image = img }
            }
        }
    }
}
