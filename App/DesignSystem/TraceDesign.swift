import SwiftUI

/// The native Trace palette. Asset variants follow the system appearance.
enum TraceTheme {
    static let ink = Color("TraceInk")
    static let paper = Color("TracePaper")
    static let card = Color("TraceCard")
    static let blue = Color.accentColor
    static let sky = Color("TraceSky")
    static let amber = Color("TraceAmber")
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

private struct TraceSignature: Shape {
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
