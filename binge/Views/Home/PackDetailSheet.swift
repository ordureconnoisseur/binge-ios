import SwiftUI

/// Fullscreen sheet listing every scene in a bulk-import Pack
/// as a 3-column 9:16 grid. Tap a tile → drop into the For You
/// reel pre-pinned to that scene with the pack's set queued
/// behind it.
///
/// Mirrors web's `PackDetailSheet.tsx`.
struct PackDetailSheet: View {
    let pack: SceneFeedPack
    /// Tile tap inside the pack sheet. The caller bubbles this
    /// up to HomeView's `onOpenInReel`, which presents the
    /// cover-reel on MainShell with the pack's scenes as the
    /// timeline. Previously this set ReelNavigator.timelineStart
    /// + dismissed, leaving the user on Home with no reel
    /// actually visible until they manually switched to For You.
    var onSceneTap: ((BingeScene) -> Void)? = nil

    @AppStorage("binge.stashUrl") private var baseURL: String = ""
    private var apiKey: String { KeychainStore.shared.stashApiKey }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(
                            .flexible(), spacing: 2
                        ),
                        count: 3
                    ),
                    spacing: 2
                ) {
                    ForEach(pack.scenes, id: \.id) { scene in
                        tile(scene)
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(pack.label)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("\(pack.sceneCount) new scenes")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    @ViewBuilder
    private func tile(_ scene: BingeScene) -> some View {
        Button {
            // Hand off to the host — HomeView wires this to
            // MainShell.drilledReel via `onOpenInReel(scene,
            // pack.scenes)`, so a cover-reel pops up with the
            // pack's scenes as a deterministic timeline starting
            // at the tap target. Dismiss this sheet on the same
            // tick so the cover slides up cleanly over Home.
            onSceneTap?(scene)
            dismiss()
        } label: {
            ZStack {
                Color(white: 0.06)
                if let url = scene.screenshotURL(base: baseURL) {
                    AuthImageView(
                        url: url,
                        apiKey: apiKey,
                        contentMode: .fill,
                        maxPixel: 512
                    )
                }
            }
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .clipped()
        }
        .buttonStyle(.plain)
    }
}
