import SwiftUI

/// A wireframe globe, the kind drawn in meridians and parallels, that turns
/// on its axis: Settings › Proxy › Status wears it. It spins briskly while
/// the proxy is being reached, keeps turning slowly once it is, and stands
/// still before a test and after a failure. Reduce Motion stops it.
///
/// Drawn in code rather than from an SF Symbol because a symbol can only be
/// rotated as a whole, which looks like a wheel, not a planet; here the
/// meridians sweep across the face, the ones at the back fainter.
struct WireGlobe: View {
    enum Pace: Equatable {
        case still, slow, fast

        /// Seconds for one turn; nil when it doesn't turn.
        var turn: Double? {
            switch self {
            case .still: return nil
            case .slow: return 9
            case .fast: return 1.6
            }
        }
    }

    var pace: Pace
    var tint: Color
    var size: CGFloat = 14

    /// Where the globe was at `since`, so a change of pace carries on from
    /// the same longitude instead of jumping.
    @State private var anchor = Anchor(phase: 0.55, since: .now)

    private struct Anchor {
        var phase: Double
        var since: Date
    }

    private var paused: Bool { pace == .still || Motion.reduced }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: paused)) { context in
            Canvas(rendersAsynchronously: false) { ctx, box in
                WireGlobe.draw(in: &ctx, box: box, longitude: angle(at: context.date))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .animation(Motion.settle, value: tint)
        .onChange(of: pace) { old, _ in
            anchor = Anchor(phase: angle(at: .now, pace: old), since: .now)
        }
        .accessibilityHidden(true)
    }

    private func angle(at date: Date, pace: Pace? = nil) -> Double {
        guard let turn = (pace ?? self.pace).turn, !Motion.reduced else { return anchor.phase }
        return anchor.phase + date.timeIntervalSince(anchor.since) / turn * 2 * .pi
    }

    /// The globe as seen from the equator: the rim, the equator and two
    /// parallels, and six half-meridians 60° apart from pole to pole, each an
    /// arc whose width follows its longitude. Those facing the viewer are
    /// drawn in full; the ones round the back show through faintly.
    static func draw(in ctx: inout GraphicsContext, box: CGSize, longitude: Double) {
        let radius = min(box.width, box.height) / 2 - 0.6
        let centre = CGPoint(x: box.width / 2, y: box.height / 2)
        let hair = StrokeStyle(lineWidth: 0.9, lineCap: .round)

        var back: [Path] = []
        var front: [Path] = []
        for k in 0..<6 {
            let lambda = longitude + Double(k) * .pi / 3
            let facing = cos(lambda) >= 0
            var path = Path()
            let steps = 18
            for i in 0...steps {
                let phi = -Double.pi / 2 + Double(i) / Double(steps) * .pi
                let point = CGPoint(
                    x: centre.x + radius * cos(phi) * sin(lambda),
                    y: centre.y - radius * sin(phi))
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            if facing { front.append(path) } else { back.append(path) }
        }

        var faint = ctx
        faint.opacity = 0.28
        for path in back {
            faint.stroke(path, with: .foreground, style: hair)
        }

        var lines = Path()
        for latitude in [-0.75, 0.0, 0.75] {
            let y = centre.y - radius * sin(latitude)
            let half = radius * cos(latitude)
            lines.move(to: CGPoint(x: centre.x - half, y: y))
            lines.addLine(to: CGPoint(x: centre.x + half, y: y))
        }
        var soft = ctx
        soft.opacity = 0.62
        soft.stroke(lines, with: .foreground, style: hair)

        var clear = ctx
        clear.opacity = 0.9
        for path in front {
            clear.stroke(path, with: .foreground, style: hair)
        }

        let rim = Path(ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius,
                                         width: radius * 2, height: radius * 2))
        ctx.stroke(rim, with: .foreground, style: StrokeStyle(lineWidth: 1.1))
    }
}
