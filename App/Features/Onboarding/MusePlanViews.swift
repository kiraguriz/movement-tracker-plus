import SwiftUI

/// The Plan page while Muse is working: no numbers, a way out that is always one tap away.
struct MusePlanWaiting: View {
    let useStandard: () -> Void

    @ScaledMetric(relativeTo: .title) private var minimumHeight = 220.0

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 18) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .accessibilityHidden(true)
                Text("Muse is building your plan")
                    .font(.title3.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .background(TraceTheme.cobalt, in: .rect(cornerRadius: 32))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier(AccessibilityID.onboardingPlanWaiting)

            Button(action: useStandard) {
                Text("Use standard plan")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .overlay(Capsule().strokeBorder(TraceTheme.line, lineWidth: 2))
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .foregroundStyle(TraceTheme.ink)
            .accessibilityIdentifier(AccessibilityID.onboardingPlanUseStandard)
        }
    }
}

/// Muse's reason for its plan, and its caution when it raised one.
struct MusePlanNote: View {
    let rationale: String
    let caution: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("From Muse", systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TraceTheme.blue)
                StubBadge()
                Text(rationale)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let caution {
                    Label(caution, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(TraceTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.onboardingPlanMuse)
    }
}

/// Why the standard plan is on screen when Muse was chosen, with a retry where one can work.
struct MusePlanFallbackNotice: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(AccessibilityID.onboardingPlanNotice)
            if let retry {
                Button("Try Again", action: retry)
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.onboardingPlanRetry)
            }
        }
        .padding(16)
        .background(TraceTheme.amber.opacity(0.15), in: .rect(cornerRadius: 20))
    }
}
