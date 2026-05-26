import SwiftUI

// "More" landing page reached via the bottom-nav burger slot.
// Two destinations: Saved (custom collections) and Settings.
// Mirrors src/tabs/MenuPage.tsx — same shape, same icons.
//
// Hosts its own NavigationStack so pushes to Settings / Saved
// slide in over the menu list with a system back chevron.
struct MenuPage: View {
    @State private var path = NavigationPath()

    enum Destination: Hashable {
        case saved
        case settings
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    row(
                        title: "Saved",
                        subtitle: "Custom collections of bookmarked scenes.",
                        systemImage: "bookmark",
                        destination: .saved
                    )
                    Divider()
                        .background(Color.white.opacity(0.06))
                        .padding(.leading, 62)
                    row(
                        title: "Settings",
                        subtitle:
                            "Stream type, lookback window, connection.",
                        systemImage: "gearshape",
                        destination: .settings
                    )
                }
                .padding(.top, 8)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    BingeLogoMark()
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationDestination(for: Destination.self) { dest in
                switch dest {
                case .saved:
                    SavedPage()
                case .settings:
                    SettingsView(mode: .normal)
                }
            }
        }
    }

    @ViewBuilder
    private func row(
        title: String,
        subtitle: String,
        systemImage: String,
        destination: Destination
    ) -> some View {
        Button {
            path.append(destination)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
