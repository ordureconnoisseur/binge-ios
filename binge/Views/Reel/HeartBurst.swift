import SwiftUI

// Pink heart-particle splash that floats up from the bottom of the
// reel slide when the user likes a scene. Direct port of the web
// HeartBurst — 14 hearts with randomized trajectory, rotation,
// scale, duration, and stagger. Each burst is self-contained: it
// generates its particles at mount, animates them via three
// concurrent withAnimation blocks (fade in / body transform /
// fade out), and the parent removes it after ~2.7s.
//
// Colors + glow are matched to the web exactly: #f472b6 fill +
// stacked drop shadows.

extension Color {
    /// Tailwind pink-400 — the "liked" color used everywhere a
    /// heart can be active (action stack, feed card, burst
    /// particles).
    static let bingeLike = Color(
        red: 0.957, green: 0.447, blue: 0.714
    )

    /// Instagram "verified" blue — used on the Discover Performers
    /// bar to mark performers the user already has in their library
    /// (visual parity with IG's verified-checkmark cyan).
    static let bingeVerified = Color(
        red: 0.220, green: 0.592, blue: 0.941  // #3897F0
    )

    /// Pale-blue tap accent used for inline links / @mentions /
    /// tag hashtags on feed cards. Matches the web's
    /// `binge-feed-card-hashtag` + `binge-performer-mention`
    /// colors — `#6aa9ff` reads well against the dark gray card
    /// background without being as saturated as `bingeVerified`.
    static let bingeLink = Color(
        red: 0.416, green: 0.663, blue: 1.0  // #6aa9ff
    )
}

extension LinearGradient {
    /// binge identity story-ring gradient. Pink (bingeLike) →
    /// purple → blue (bingeLink) across topLeading → bottomTrailing.
    /// Replaces the IG-quote pink→orange ring so every "performer
    /// has new content" affordance ties back to binge's own
    /// two-tone palette. Web ships the same stops via
    /// `.binge-story-ring` in global.css.
    static let bingeStoryRing = LinearGradient(
        colors: [
            Color(red: 0.957, green: 0.447, blue: 0.714), // #f472b6 pink
            Color(red: 0.659, green: 0.333, blue: 0.969), // #a855f7 purple
            Color(red: 0.416, green: 0.663, blue: 1.000), // #6aa9ff blue
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct HeartBurst: View {
    let particleCount: Int = 14
    @State private var particles: [Particle] = []

    struct Particle: Identifiable {
        let id = UUID()
        let xStart: CGFloat   // 0..1 fraction of slide width
        let xEnd: CGFloat     // px horizontal drift
        let rise: CGFloat     // fraction of slide height to rise
        let duration: Double
        let delay: Double
        let scaleStart: CGFloat
        let scaleEnd: CGFloat
        let rotStart: Double
        let rotEnd: Double
        let size: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Color.clear
                ForEach(particles) { p in
                    ParticleView(particle: p, slideSize: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { particles = Self.makeParticles(particleCount) }
    }

    private static func makeParticles(_ count: Int) -> [Particle] {
        (0..<count).map { _ in
            Particle(
                xStart: CGFloat.random(in: 0.15...0.85),
                xEnd: CGFloat.random(in: -80...80),
                rise: CGFloat.random(in: 0.85...1.15),
                duration: Double.random(in: 1.8...2.4),
                delay: Double.random(in: 0...0.28),
                scaleStart: CGFloat.random(in: 0.45...0.75),
                scaleEnd: CGFloat.random(in: 0.85...1.25),
                rotStart: Double.random(in: -25...25),
                rotEnd: Double.random(in: -45...45),
                size: CGFloat.random(in: 18...32)
            )
        }
    }
}

// One particle. Three concurrent animations:
//   1. Quick opacity 0→1 fade-in at start
//   2. Body transform (translate up + horizontal drift + scale +
//      rotation) over the full duration with the web's same
//      cubic-bezier easing
//   3. Opacity 1→0 fade-out in the last 30% of the lifetime
//
// All driven via .onAppear so the animations begin the instant the
// view mounts, regardless of when the parent renders.
private struct ParticleView: View {
    let particle: HeartBurst.Particle
    let slideSize: CGSize

    @State private var bodyTransformed: Bool = false
    @State private var fadedIn: Bool = false
    @State private var fadedOut: Bool = false

    var body: some View {
        // Starting position: just off the bottom of the slide. The
        // body-transform animation interpolates from this to the
        // final translated/rotated/scaled state.
        let startX = slideSize.width * particle.xStart
        HeartShape()
            .fill(Color.bingeLike)
            .frame(width: particle.size, height: particle.size)
            .shadow(color: Color.bingeLike.opacity(0.7), radius: 6)
            .shadow(color: Color.bingeLike.opacity(0.35), radius: 12)
            .offset(
                x: bodyTransformed ? particle.xEnd : 0,
                y: bodyTransformed
                    ? -slideSize.height * particle.rise
                    : 0
            )
            .rotationEffect(
                .degrees(bodyTransformed
                    ? particle.rotEnd
                    : particle.rotStart)
            )
            .scaleEffect(
                bodyTransformed
                    ? particle.scaleEnd
                    : particle.scaleStart
            )
            .position(x: startX, y: slideSize.height + 32)
            .opacity(fadedIn ? (fadedOut ? 0 : 1) : 0)
            .onAppear {
                // Body transform — full duration, cubic-bezier
                // matches the web's @keyframes binge-heart-rise
                // easing curve.
                withAnimation(
                    .timingCurve(0.25, 0.7, 0.45, 1,
                                 duration: particle.duration)
                    .delay(particle.delay)
                ) {
                    bodyTransformed = true
                }
                // Fade in over the first 8% of the lifetime.
                withAnimation(
                    .easeOut(duration: particle.duration * 0.08)
                        .delay(particle.delay)
                ) {
                    fadedIn = true
                }
                // Fade out over the last 30%.
                withAnimation(
                    .linear(duration: particle.duration * 0.30)
                        .delay(particle.delay + particle.duration * 0.70)
                ) {
                    fadedOut = true
                }
            }
    }
}
