import SwiftUI

// A design harness for the floating nav, reachable only by launching
// with `-navPreview`. Nothing in the shipping app links to it.
//
// It exists because the nav was iterated on six times without anyone
// being able to SEE it: the phone cannot be screenshotted remotely, so
// every change was a guess, and one of them broke the reel. The
// simulator can be screenshotted, but the real app needs a Stash server
// and an API key to reach a screen that has a nav on it. This gets the
// component on screen over representative content in one launch, with
// the real asset catalogue and the real glass.
//
// Delete once the nav is settled.
struct NavPreviewHarness: View {
    @State private var tab: BingeTab = .foryou
    @State private var offset: CGFloat = 0

    static var isRequested: Bool {
        CommandLine.arguments.contains("-navPreview")
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Something with real tonal range behind the glass. A flat
            // colour tells you nothing: the whole question is what the
            // material does with content passing under it, and against
            // black it does almost nothing, which is exactly how the
            // first attempts came to look like a grey pill.
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(0..<14, id: \.self) { i in
                        LinearGradient(
                            colors: gradient(for: i),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(height: 180)
                        .overlay(alignment: .bottomLeading) {
                            Text("card \(i)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(10)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .id(i)
                    }
                }
                .padding(.horizontal, 12)
            }
            .contractsBottomNav()
            .scrollEdgeEffectStyle(nil, for: .bottom)
            // Drives itself, so the scroll rule can be screenshotted.
            // The simulator has no scriptable tap or swipe, and the
            // rule is about DIRECTION, so a static screenshot cannot
            // show whether it works. -navAutoScroll scrolls down at
            // 3s and back up at 7s; shoot at 5s and 9s.
            // Cycles the selection so the pill's travel can be caught
            // mid-flight. A still cannot show whether a shape moved or
            // teleported, and the simulator has no scriptable tap.
            .task {
                guard CommandLine.arguments.contains("-navCycleTabs")
                else { return }
                let order: [BingeTab] = [
                    .home, .explore, .menu, .foryou, .following,
                ]
                try? await Task.sleep(for: .seconds(2))
                for t in order {
                    // Same transaction the nav's own button uses.
                    // Assigning bare here tested the harness rather
                    // than the button and made the pill look like it
                    // never animated.
                    withAnimation(
                        .spring(response: 0.42, dampingFraction: 0.78)
                    ) {
                        tab = t
                    }
                    try? await Task.sleep(for: .milliseconds(900))
                }
            }
            .task {
                guard CommandLine.arguments.contains("-navAutoScroll")
                else { return }
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeInOut(duration: 1)) {
                    proxy.scrollTo(9, anchor: .top)
                }
                try? await Task.sleep(for: .seconds(4))
                withAnimation(.easeInOut(duration: 1)) {
                    proxy.scrollTo(1, anchor: .top)
                }
            }
            }

            BingeBottomNav(selected: $tab)
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func gradient(for i: Int) -> [Color] {
        let hues: [Double] = [0.02, 0.09, 0.55, 0.78, 0.33, 0.88, 0.12]
        let h = hues[i % hues.count]
        return [
            Color(hue: h, saturation: 0.55, brightness: 0.85),
            Color(hue: h + 0.08, saturation: 0.7, brightness: 0.35),
        ]
    }
}
