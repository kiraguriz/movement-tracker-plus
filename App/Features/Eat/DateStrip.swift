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
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(days, id: \.self) { day in
                        chip(day)
                            .id(day)
                    }
                }
                .padding(.horizontal, 12)
            }
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) {
                withAnimation(.smooth) { proxy.scrollTo(selection, anchor: .center) }
            }
        }
        .accessibilityIdentifier(AccessibilityID.dateStrip)
    }

    private func chip(_ day: LocalDay) -> some View {
        let date = day.date(in: timeZone)
        let isSelected = day == selection
        return Button {
            selection = day
        } label: {
            VStack(spacing: 2) {
                Text(date, format: .dateTime.weekday(.narrow))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                Text(day.day, format: .number)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : (day == today ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary)))
                Circle()
                    .fill(loggedDays.contains(day) ? (isSelected ? Color.white : Color.accentColor) : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(width: 44, height: 64)
            .background {
                if isSelected {
                    Capsule().fill(Color.accentColor)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(date, format: .dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.day(day))
    }
}
