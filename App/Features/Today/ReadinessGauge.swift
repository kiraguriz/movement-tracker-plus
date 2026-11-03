import Domain
import SwiftUI

/// Three upright marks, filled from the left: ready fills three, steady two, easy one. The count carries the
/// meaning, not a hue; only the lowest band borrows the existing attention amber, and the brand blue is never used
/// for "good".
struct ReadinessGauge: View {
    let band: ReadinessBand
    var height: CGFloat = 26

    private var filled: Int {
        switch band {
        case .ready: 3
        case .steady: 2
        case .easy: 1
        }
    }

    private var tint: Color { band == .easy ? TraceTheme.amber : TraceTheme.ink }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(index < filled ? tint : TraceTheme.ink.opacity(0.14))
                    .frame(width: 7, height: height)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    VStack(spacing: 16) {
        ForEach(ReadinessBand.allCases, id: \.self) { ReadinessGauge(band: $0) }
    }
    .padding()
    .background(TraceTheme.card)
}
