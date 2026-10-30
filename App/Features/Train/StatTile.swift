import SwiftUI

/// A number with its name on a rounded tile: the set review and the workout summary use it.
struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var identifier: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier ?? "")
    }
}

/// Tiles side by side while they fit, one per row at the largest text sizes.
struct StatTileGrid<Content: View>: View {
    @ScaledMetric private var minimum: Double
    private let content: Content

    init(minimum: Double, @ViewBuilder content: () -> Content) {
        _minimum = ScaledMetric(wrappedValue: minimum, relativeTo: .subheadline)
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 12)], spacing: 12) {
            content
        }
    }
}
