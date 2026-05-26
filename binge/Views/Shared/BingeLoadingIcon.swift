import SwiftUI

/// Brand-aligned loading glyph: the actual binge silhouette
/// (template-rendered SVG asset, viewBox 0 0 512 512) filled with
/// an angular pink → purple → blue gradient whose start angle
/// rotates continuously. The path stays still — only the gradient
/// rotates — so the brand mark is always recognisable.
///
/// Drives the rotation via `TimelineView(.animation)`: every frame
/// the gradient's start angle is derived from `Date.now` modulo
/// the rotation period. No `@State`, no `withAnimation` retain
/// cycles, no animation hangs across view re-mount.
struct BingeLoadingIcon: View {
    /// Time for one full revolution.
    var period: Double = 3.0

    var body: some View {
        TimelineView(.animation) { context in
            // Map elapsed seconds → 0…360°. Wrapping via
            // truncatingRemainder gives a seamless loop because the
            // colour palette starts and ends on the same pink.
            let elapsed =
                context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period)
            let phase = elapsed / period * 360.0

            Image("BingeLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(
                    AngularGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.957, green: 0.447, blue: 0.714),
                                // #f472b6 (bingeLike pink)
                            Color(red: 0.659, green: 0.333, blue: 0.969),
                                // #a855f7 (mid purple)
                            Color(red: 0.416, green: 0.663, blue: 1.000),
                                // #6aa9ff (bingeLink blue)
                            Color(red: 0.659, green: 0.333, blue: 0.969),
                                // mirror purple
                            Color(red: 0.957, green: 0.447, blue: 0.714),
                                // wrap back to pink for a seamless loop
                        ]),
                        center: .center,
                        startAngle: .degrees(phase),
                        endAngle: .degrees(phase + 360)
                    )
                )
                .shadow(
                    color: Color(
                        red: 0.659, green: 0.333, blue: 0.969
                    ).opacity(0.35),
                    radius: 8
                )
        }
    }
}
