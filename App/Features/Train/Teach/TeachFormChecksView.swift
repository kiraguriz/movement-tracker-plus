import CoachKit
import MotionCore
import SwiftUI

/// What Muse chose for the taught exercise, under the replay result: the checks that survived the phone's own
/// replay, each with Muse's reason and the number it holds the rep to. Shows nothing when Muse is off.
struct TeachFormChecksSection: View {
    @Bindable var checks: TeachFormChecks

    var body: some View {
        switch checks.state {
        case .off:
            EmptyView()
        case .thinking:
            HStack(spacing: 12) {
                ProgressView()
                Text("teach.checks.thinking")
                    .font(.subheadline)
                    .foregroundStyle(TraceTheme.secondary)
            }
            .frame(minHeight: 44)
            .testIdentifier(AccessibilityID.teachChecksThinking)
        case .plain:
            Text("teach.checks.none")
                .font(.subheadline)
                .foregroundStyle(TraceTheme.secondary)
                .frame(minHeight: 44, alignment: .leading)
                .testIdentifier(AccessibilityID.teachChecksNone)
        case .ready:
            ready
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("teach.checks.title")
                .font(.headline)
                .foregroundStyle(TraceTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("teach.checks.passed \(checks.items.count) \(checks.proposedCount)")
                .font(.subheadline)
                .foregroundStyle(TraceTheme.secondary)
            ForEach(checks.items) { item in
                row(item)
            }
            Toggle("teach.checks.use", isOn: $checks.isEnabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier(AccessibilityID.teachChecksUse)
            if let saw = checks.saw {
                WhatMuseSawView(saw: saw, images: checks.sentImages)
            }
        }
        .testIdentifier(AccessibilityID.teachChecks)
    }

    private func row(_ item: TeachFormChecks.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: LiveText.cue(item.template.cue))
                .font(.body.weight(.semibold))
                .foregroundStyle(TraceTheme.ink)
            if !item.why.isEmpty {
                Text(verbatim: item.why)
                    .font(.subheadline)
                    .foregroundStyle(TraceTheme.ink)
            }
            Text(verbatim: Self.limit(item.template, item.threshold))
                .font(.footnote)
                .foregroundStyle(TraceTheme.secondary)
            if item.wasRelaxed {
                Text(verbatim: Self.localized("teach.check.eased", TeachFormChecks.text(item.template, item.proposed)))
                    .font(.footnote)
                    .foregroundStyle(TraceTheme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(TraceTheme.card, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.teachCheck(item.template))
    }

    /// "Takes at least 0.8 s to lower", from a sentence per template that has the number in it.
    private static func limit(_ template: MotionCore.TaughtRuleTemplate, _ value: Double) -> String {
        localized("teach.check.\(template.rawValue)", TeachFormChecks.text(template, value))
    }

    /// A catalog sentence with one `%@` filled in; the key is built at run time, so `Text` cannot look it up.
    private static func localized(_ key: String, _ argument: String) -> String {
        String(format: Bundle.main.localizedString(forKey: key, value: key, table: nil), argument)
    }
}
