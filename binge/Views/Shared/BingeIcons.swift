import SwiftUI

// Pixel-for-pixel ports of the web binge icons from
// src/components/ActionStack.tsx. SF Symbols don't share the same
// proportions or stroke weight, so even with weight tuning they
// read as "different brand" — keeping the action row visually
// identical between web and iOS by sharing the actual SVG path
// data here.
//
// Web icon details:
//   - 24x24 viewBox
//   - stroke="currentColor", stroke-width=1.5, round caps + joins
//   - filled variants use fill="currentColor", stroke=0
//
// One shape struct per icon. They all draw inside a 24x24 logical
// canvas and scale uniformly to the surrounding frame. The
// BingeIcon view at the bottom wraps them with the stroke vs fill
// switch matching the web's `filled` prop.

// MARK: - Coordinate helper

/// Maps the icon's 24x24 logical SVG viewBox onto the actual draw
/// rect, centered with uniform scale (no skew). Equivalent to
/// SVG's `viewBox="0 0 24 24"` + `preserveAspectRatio="xMidYMid meet"`.
private struct IconCanvas {
    let scale: CGFloat
    let dx: CGFloat
    let dy: CGFloat

    init(rect: CGRect) {
        self.scale = min(rect.width, rect.height) / 24
        self.dx = (rect.width - 24 * scale) / 2
        self.dy = (rect.height - 24 * scale) / 2
    }

    /// SVG-space point → canvas point.
    func pt(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: dx + x * scale, y: dy + y * scale)
    }

    /// SVG-space length → canvas length.
    func size(_ v: Double) -> CGFloat { v * scale }
}

// MARK: - Shapes

// SVG: M19 14 c1.49 -1.46 3 -3.21 3 -5.5
//      A 5.5 5.5 0 0 0 16.5 3 c-1.76 0 -3 .5 -4.5 2
//      c-1.5 -1.5 -2.74 -2 -4.5 -2
//      A 5.5 5.5 0 0 0 2 8.5 c0 2.29 1.51 4.04 3 5.5
//      l7 7 Z
//
// The two `A` arc commands (right + left lobes) are approximated
// as cubic Béziers — each is a 90° arc on a radius-5.5 circle and
// the standard (4/3)·tan(22.5°)·r ≈ 3.04 control-point distance
// gives a visually identical curve.
struct HeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = IconCanvas(rect: rect)
        var p = Path()
        p.move(to: c.pt(19, 14))
        p.addCurve(
            to: c.pt(22, 8.5),
            control1: c.pt(20.49, 12.54),
            control2: c.pt(22, 10.79)
        )
        // Right lobe top: arc from (22, 8.5) to (16.5, 3) around
        // center (16.5, 8.5), CCW.
        p.addCurve(
            to: c.pt(16.5, 3),
            control1: c.pt(22, 5.46),
            control2: c.pt(19.54, 3)
        )
        // Dip between lobes — peak comes down to (12, 5).
        p.addCurve(
            to: c.pt(12, 5),
            control1: c.pt(14.74, 3),
            control2: c.pt(13.5, 3.5)
        )
        // Mirror on left side — out to (7.5, 3).
        p.addCurve(
            to: c.pt(7.5, 3),
            control1: c.pt(10.5, 3.5),
            control2: c.pt(9.26, 3)
        )
        // Left lobe top: arc from (7.5, 3) to (2, 8.5) around
        // center (7.5, 8.5), CCW.
        p.addCurve(
            to: c.pt(2, 8.5),
            control1: c.pt(4.46, 3),
            control2: c.pt(2, 5.46)
        )
        // Down-left into the bottom point.
        p.addCurve(
            to: c.pt(5, 14),
            control1: c.pt(2, 10.79),
            control2: c.pt(3.51, 12.54)
        )
        p.addLine(to: c.pt(12, 21))
        p.closeSubpath() // line back to (19, 14)
        return p
    }
}

// SVG: polygon points="12 2 15.09 8.26 22 9.27 17 14.14
//      18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26"
struct StarShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = IconCanvas(rect: rect)
        let pts: [(Double, Double)] = [
            (12, 2), (15.09, 8.26), (22, 9.27), (17, 14.14),
            (18.18, 21.02), (12, 17.77), (5.82, 21.02),
            (7, 14.14), (2, 9.27), (8.91, 8.26),
        ]
        var p = Path()
        p.move(to: c.pt(pts[0].0, pts[0].1))
        for i in 1..<pts.count {
            p.addLine(to: c.pt(pts[i].0, pts[i].1))
        }
        p.closeSubpath()
        return p
    }
}

// SVG: four rounded rects 7×7 with rx=1 at positions (3,3) (14,3) (14,14) (3,14)
struct GridShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = IconCanvas(rect: rect)
        var p = Path()
        let r = c.size(1)
        for (x, y) in [(3.0, 3.0), (14.0, 3.0), (14.0, 14.0), (3.0, 14.0)] {
            p.addRoundedRect(
                in: CGRect(
                    origin: c.pt(x, y),
                    size: CGSize(width: c.size(7), height: c.size(7))
                ),
                cornerSize: CGSize(width: r, height: r)
            )
        }
        return p
    }
}

// IG-style comment-bubble outline. Mirrors the web's `PencilIcon`
// SVG: `M 20.656 17.008 a 9.993 9.993 0 1 0 -3.59 3.615 L 22 22 Z`
// — a near-complete circle (large arc, ~330°) with a short tail
// pointing to (22, 22) at the bottom-right. Kept under the
// `.pencil` Glyph case for parity with web (which kept the type
// name for backward compat after the same redesign).
//
// The web's SVG uses a single elliptical arc; we approximate
// with SwiftUI's addArc(center:radius:startAngle:endAngle:...).
// Math: vector from center (≈ 12, 12) to start (20.656, 17.008)
// is (8.656, 5.008) → angle ≈ atan2(5.008, 8.656) ≈ 30°. End at
// (17.066, 20.623) → angle ≈ atan2(8.623, 5.066) ≈ 60°. SVG
// flags large-arc=1 + sweep=0 in the screen-y-down coordinate
// space resolve to a clockwise long arc, so SwiftUI's
// clockwise=true matches.
struct PencilShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = IconCanvas(rect: rect)
        // Pull the geometry numbers straight from the SVG so any
        // future tweaks to the web's path port over by literal
        // substitution.
        let center = c.pt(12, 12)
        let radius = c.size(9.993)
        let start = c.pt(20.656, 17.008)
        let end = c.pt(17.066, 20.623)
        let tail = c.pt(22, 22)

        let startAngle = Angle(
            radians: atan2(start.y - center.y, start.x - center.x)
        )
        let endAngle = Angle(
            radians: atan2(end.y - center.y, end.x - center.x)
        )

        var p = Path()
        p.move(to: start)
        p.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle,
            endAngle: endAngle,
            clockwise: true
        )
        p.addLine(to: tail)
        p.closeSubpath()
        return p
    }
}

// SVG: m19 21 -7 -4 -7 4 V 5 a 2 2 0 0 1 2 -2 h 10 a 2 2 0 0 1 2 2 z
struct BookmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = IconCanvas(rect: rect)
        var p = Path()
        p.move(to: c.pt(19, 21))
        p.addLine(to: c.pt(12, 17))
        p.addLine(to: c.pt(5, 21))
        p.addLine(to: c.pt(5, 5))
        // a 2 2 0 0 1 2 -2  — top-left corner, CCW arc on r=2
        p.addCurve(
            to: c.pt(7, 3),
            control1: c.pt(5, 3.9),
            control2: c.pt(5.9, 3)
        )
        p.addLine(to: c.pt(17, 3))
        // a 2 2 0 0 1 2 2  — top-right corner
        p.addCurve(
            to: c.pt(19, 5),
            control1: c.pt(18.1, 3),
            control2: c.pt(19, 3.9)
        )
        p.closeSubpath()
        return p
    }
}

// SVG: three dots at x=5, 12, 19, all y=12, radius 1.2
struct MoreShape: Shape {
    func path(in rect: CGRect) -> Path {
        let c = IconCanvas(rect: rect)
        var p = Path()
        let r = c.size(1.2)
        for x in [5.0, 12.0, 19.0] {
            let center = c.pt(x, 12)
            p.addEllipse(
                in: CGRect(
                    x: center.x - r,
                    y: center.y - r,
                    width: r * 2,
                    height: r * 2
                )
            )
        }
        return p
    }
}

// MARK: - View wrapper

// Single entry point for binge icons. Mirrors the web's filled vs
// stroked branch via the `filled` parameter on each glyph case.
// Stroke 1.5pt + round caps/joins matches ICON_LINE_PROPS from
// ActionStack.tsx exactly.
struct BingeIcon: View {
    enum Glyph {
        case heart(filled: Bool)
        case star(filled: Bool)
        case grid(filled: Bool)
        case pencil
        case bookmark(filled: Bool)
        case more
    }

    let glyph: Glyph
    var size: CGFloat = 22
    var color: Color = .white
    var strokeWidth: CGFloat = 1.5

    var body: some View {
        Group {
            switch glyph {
            case .heart(let filled):
                styled(HeartShape(), filled: filled)
            case .star(let filled):
                styled(StarShape(), filled: filled)
            case .grid(let filled):
                styled(GridShape(), filled: filled)
            case .pencil:
                styled(PencilShape(), filled: false)
            case .bookmark(let filled):
                styled(BookmarkShape(), filled: filled)
            case .more:
                // Dots are always filled — they're tiny circles,
                // a stroke would look wrong.
                styled(MoreShape(), filled: true)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func styled<S: Shape>(_ shape: S, filled: Bool) -> some View {
        if filled {
            shape.fill(color)
        } else {
            shape.stroke(
                color,
                style: StrokeStyle(
                    lineWidth: strokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
    }
}
