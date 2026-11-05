import SwiftUI

/// The native Trace palette. Asset variants follow the system appearance.
enum TraceTheme {
    static let ink = Color("TraceInk")
    static let paper = Color("TracePaper")
    static let card = Color("TraceCard")
    static let blue = Color.accentColor
    static let sky = Color("TraceSky")
    static let amber = Color("TraceAmber")
    /// Amber for text and glyphs on paper or card; the plain amber is too light to read there in light mode.
    static let amberInk = Color("TraceAmberInk")
    static let carbs = Color("TraceCarbs")
    static let vermilion = Color("TraceVermilion")
    static let secondary = Color("TraceSecondary")
    static let line = Color("TraceLine")
    static let night = Color(red: 11 / 255, green: 13 / 255, blue: 18 / 255)
    static let cobalt = Color(red: 43 / 255, green: 75 / 255, blue: 1)

    static func numeral(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy).width(.compressed).monospacedDigit()
    }

    static let label: Font = .caption2.weight(.bold).width(.expanded)
}

/// Motion comes from springs named by how they should feel, not from durations. Each value was derived from its
/// feel words with the /feel model (mass, stiffness, damping), so the time a motion takes follows from the model.
enum TraceMotion {
    /// "crisp": 3.8 Hz, ζ 0.92, no visible overshoot. The rep count must read at a glance from across the room.
    static let count = Animation.interpolatingSpring(mass: 1, stiffness: 570.1, damping: 43.93)
    /// "snappy, light": 3.2 Hz, ζ 0.72, a 4% pop. A cue arrives with a small lift that draws the eye.
    static let cue = Animation.interpolatingSpring(mass: 0.45, stiffness: 181.2, damping: 13)
    /// "heavy, snappy": 2.1 Hz, ζ 0.78, 2% overshoot. A full screen lands with weight and does not wobble.
    static let screen = Animation.interpolatingSpring(mass: 3, stiffness: 543.6, damping: 63)
    /// "smooth": 1.8 Hz, critically damped. Scrolled content never travels past where it stops.
    static let scroll = Animation.interpolatingSpring(mass: 1, stiffness: 127.9, damping: 22.62)
    /// "gentle": 1.2 Hz, critically damped. The ripple a counted rep sends out from the trace head.
    static let ripple = Spring(mass: 1, stiffness: 56.8, damping: 15.08)
}

extension View {
    func traceMetricLabel() -> some View {
        font(TraceTheme.label)
            .textCase(.uppercase)
            .tracking(0.6)
    }
}

enum TraceRepStatus {
    case good, fix, major, partial

    var color: Color {
        switch self {
        case .good: TraceTheme.blue
        case .fix, .partial: TraceTheme.amber
        case .major: TraceTheme.vermilion
        }
    }
}

/// Shape and color both distinguish the motion engine's assessment.
struct TraceMark: View {
    let status: TraceRepStatus

    var body: some View {
        Group {
            if status == .partial {
                Circle().strokeBorder(status.color, lineWidth: 2)
            } else if status == .major {
                RoundedRectangle(cornerRadius: 2).fill(status.color)
            } else {
                Circle().fill(status.color)
            }
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

struct TraceTally: View {
    let count: Int
    var color: Color = TraceTheme.ink

    var body: some View {
        Canvas { context, size in
            guard count > 0 else { return }
            let step = min(5, size.width / CGFloat(count))
            var marks = Path()
            for index in 0..<count {
                let x = CGFloat(index) * step + 1
                marks.move(to: CGPoint(x: x, y: 1))
                marks.addLine(to: CGPoint(x: x, y: size.height - 1))
            }
            context.stroke(marks, with: .color(color), style: StrokeStyle(lineWidth: min(2, step * 0.55), lineCap: .round))
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }
}

/// The same U-shaped motion signature appears in the app icon and Coach entry point.
struct TraceCoachGlyph: View {
    var size: CGFloat = 20

    var body: some View {
        ZStack {
            Circle().fill(TraceTheme.cobalt)
            TraceSignature()
                .stroke(.white, style: StrokeStyle(lineWidth: size * 0.1, lineCap: .round))
                .padding(size * 0.23)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct TraceSignature: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.height * 0.2))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.height * 0.9),
                      control1: CGPoint(x: rect.width * 0.3, y: rect.height * 0.2),
                      control2: CGPoint(x: rect.width * 0.3, y: rect.height * 0.9))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.height * 0.2),
                      control1: CGPoint(x: rect.width * 0.7, y: rect.height * 0.9),
                      control2: CGPoint(x: rect.width * 0.7, y: rect.height * 0.2))
        return path
    }
}

/// A few reps drawn as the trace draws them: hold at the top, ease down, hold, ease back up.
struct TraceRepWave: Shape {
    let reps: Int

    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width / CGFloat(max(reps, 1))
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for rep in 0..<reps {
            let x = rect.minX + CGFloat(rep) * width
            path.addLine(to: CGPoint(x: x + width * 0.1, y: rect.minY))
            path.addCurve(
                to: CGPoint(x: x + width * 0.55, y: rect.maxY),
                control1: CGPoint(x: x + width * 0.32, y: rect.minY),
                control2: CGPoint(x: x + width * 0.33, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: x + width * 0.62, y: rect.maxY))
            path.addCurve(
                to: CGPoint(x: x + width * 0.88, y: rect.minY),
                control1: CGPoint(x: x + width * 0.75, y: rect.maxY),
                control2: CGPoint(x: x + width * 0.75, y: rect.minY)
            )
            path.addLine(to: CGPoint(x: x + width, y: rect.minY))
        }
        return path
    }
}
