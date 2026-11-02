import Domain
import SwiftUI

/// A horizontally scrolling row of days, oldest first, ending today.
struct DateStrip: View {
    let days: [LocalDay]
    let today: LocalDay
    let loggedDays: Set<LocalDay>
    let timeZone: TimeZone
    @Binding var selection: LocalDay

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(days, id: \.self) { day in
                            chip(day, width: max(44, min(64, (geometry.size.width - 56) / 7)))
                                .id(day)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .onAppear { proxy.scrollTo(selection, anchor: .center) }
                .onChange(of: selection) {
                    withAnimation(.smooth) { proxy.scrollTo(selection, anchor: .center) }
                }
            }
            .frame(height: 70)
        }
        // A navigation control, like the tab bar: it stops growing before the numbers outgrow their chips.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityIdentifier(AccessibilityID.dateStrip)
    }

    private func chip(_ day: LocalDay, width: CGFloat) -> some View {
        let date = day.date(in: timeZone)
        let isSelected = day == selection
        return Button {
            selection = day
        } label: {
            VStack(spacing: 4) {
                Text(date, format: .dateTime.weekday(.narrow))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(TraceTheme.paper.opacity(0.85)) : AnyShapeStyle(TraceTheme.secondary))
                Text(day.day, format: .number)
                    .font(TraceTheme.numeral(24))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? TraceTheme.paper : TraceTheme.ink)
                Circle()
                    .fill(loggedDays.contains(day) ? (isSelected ? TraceTheme.paper : TraceTheme.blue) : Color.clear)
                    .frame(width: 4, height: 4)
            }
            .frame(width: width, height: 66)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 22).fill(TraceTheme.ink)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(date, format: .dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(loggedDays.contains(day) ? Text("Meals logged") : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.day(day))
    }
}
