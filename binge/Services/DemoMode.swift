import SwiftUI

/// Demo mode — when on, binge shows entirely fictional, SFW content
/// instead of the user's Stash library, for capturing App Store
/// screenshots/footage with nothing real on screen. Toggled from
/// Settings → Capture, or a `-binge.demoMode YES` launch argument.
enum DemoMode {
    static let storageKey = "binge.demoMode"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: storageKey) }

    /// Demo media is a sentinel HTTPS URL — using a real scheme means the
    /// app's existing "base + path" URL builders (which only pass through
    /// http-prefixed strings) leave it untouched instead of prepending the
    /// Stash base. AuthImageView matches this host and renders a gradient
    /// instead of fetching. The seed is the path component.
    static let host = "binge.demo"
    static func mediaURL(_ seed: String) -> String { "https://\(host)/\(seed)" }
}

/// Deterministic SFW gradient placeholder. Demo media is just a seeded
/// gradient — no real images or video — so the UI looks populated and
/// clean for App Store capture. The hue is a stable hash of the seed so
/// the same scene/performer always gets the same colour.
struct DemoGradient: View {
    let seed: String

    private var hue: Double {
        var h = 0
        for b in seed.utf8 { h = (h &* 31 &+ Int(b)) & 0x00ff_ffff }
        return Double(h % 360) / 360.0
    }

    var body: some View {
        let top = Color(hue: hue, saturation: 0.5, brightness: 0.7)
        let bottom = Color(
            hue: (hue + 0.1).truncatingRemainder(dividingBy: 1),
            saturation: 0.62,
            brightness: 0.38
        )
        LinearGradient(
            colors: [top, bottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
