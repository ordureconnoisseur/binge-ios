import SwiftUI

// Tap-up sheet showing the scene's full title, description, tags,
// and (when the user swipes the sheet up to its .large detent)
// the underlying file's technical details.
//
// Opened when the user taps the caption line on a reel slide.
// `.medium` lands the user on the description + tags; dragging the
// sheet higher reveals "Technical" (path, size, resolution, etc).
struct SceneDetailsSheet: View {
    let scene: BingeScene

    @Environment(\.dismiss) private var dismiss
    @Environment(FilterNavigator.self) private var filterNav

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let title = scene.title, !title.isEmpty {
                        Text(title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let details = scene.details, !details.isEmpty {
                        Text(details)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !scene.tags.isEmpty {
                        tagsSection
                    }
                    if scene.files.first != nil {
                        techSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
            .background(Color(white: 0.07).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(Color(white: 0.07), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        // .medium opens on the description; user drags up to .large
        // for the tech-details section.
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // Tags rendered as per-tag buttons that filter the For You
    // reel by the tapped tag. Matches the web HashtagRow and the
    // home feed card's tagRow.
    @ViewBuilder
    private var tagsSection: some View {
        FlowLayout(spacing: 4) {
            ForEach(scene.tags, id: \.id) { tag in
                Button {
                    filterNav.active = FilterNavigator.adHocTag(
                        id: tag.id, name: tag.name
                    )
                    dismiss()
                } label: {
                    Text("#\(tag.name)")
                        .font(.system(size: 13))
                        .foregroundColor(Color.bingeLink)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    // MARK: - Technical section

    @ViewBuilder
    private var techSection: some View {
        let f = scene.files.first!
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 6)
            Text("TECHNICAL")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.white.opacity(0.55))

            VStack(alignment: .leading, spacing: 8) {
                if let path = f.path, !path.isEmpty {
                    techRow(label: "Path", value: path, monospace: true)
                }
                if let res = Self.formatResolution(f) {
                    techRow(label: "Resolution", value: res)
                }
                if let dur = Self.formatDuration(f.duration) {
                    techRow(label: "Duration", value: dur)
                }
                if let size = Self.formatSize(f.size) {
                    techRow(label: "Size", value: size)
                }
                if let vc = f.videoCodec, !vc.isEmpty {
                    techRow(label: "Video", value: vc)
                }
                if let ac = f.audioCodec, !ac.isEmpty {
                    techRow(label: "Audio", value: ac)
                }
                if let fr = Self.formatFrameRate(f.frameRate) {
                    techRow(label: "Frame rate", value: fr)
                }
                if let br = Self.formatBitRate(f.bitRate) {
                    techRow(label: "Bit rate", value: br)
                }
            }
        }
    }

    @ViewBuilder
    private func techRow(
        label: String,
        value: String,
        monospace: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(
                    monospace
                        ? .system(size: 12, design: .monospaced)
                        : .system(size: 13)
                )
                .foregroundStyle(.white.opacity(0.88))
                .textSelection(.enabled)
                .lineLimit(monospace ? nil : 1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Formatters

    private static func formatResolution(
        _ file: BingeScene.FileInfo
    ) -> String? {
        guard let w = file.width, let h = file.height, w > 0, h > 0
        else { return nil }
        return "\(w) × \(h)"
    }

    /// "12:34" or "1:23:45". Seconds rounded.
    private static func formatDuration(_ seconds: Double?) -> String? {
        guard let s = seconds, s > 0 else { return nil }
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    /// Bytes → "1.4 GB" / "256 MB" / "12 KB" using
    /// ByteCountFormatter for locale-aware formatting.
    private static func formatSize(_ bytes: Int?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useKB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    /// "29.97 fps" / "30 fps" — drops the decimal when whole.
    private static func formatFrameRate(_ fps: Double?) -> String? {
        guard let fps, fps > 0 else { return nil }
        if fps.truncatingRemainder(dividingBy: 1) < 0.01 {
            return "\(Int(fps.rounded())) fps"
        }
        return String(format: "%.2f fps", fps)
    }

    /// Bit rate (bits/s) → "5.2 Mbps" / "920 kbps".
    private static func formatBitRate(_ bps: Int?) -> String? {
        guard let bps, bps > 0 else { return nil }
        let mbps = Double(bps) / 1_000_000
        if mbps >= 1 {
            return String(format: "%.1f Mbps", mbps)
        }
        return "\(bps / 1000) kbps"
    }
}
