import SwiftUI

struct OnboardingWelcomeView: View {
    @Environment(\.onboardingWide) private var wide
    let begin: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize = 40.0
    @ScaledMetric(relativeTo: .largeTitle) private var repSize = 180.0

    var body: some View {
        ScrollView {
            OnboardingColumns {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Movement Tracker+")
                        .font(.headline)
                    Text("Every rep.\nMade visible.")
                        .font(.system(size: headlineSize, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if !wide { demo }
                    Text("Track your training with the camera. Focus on every rep.")
                        .font(.body)
                        .foregroundStyle(TraceTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, wide ? 28 : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                if wide { demo }
            }
            .frame(maxWidth: wide ? 1040 : 520, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, wide ? 48 : 20)
            .padding(.vertical, wide ? 32 : 16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(TraceTheme.paper)
        .foregroundStyle(TraceTheme.ink)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: wide ? 8 : 14) {
                OnboardingAction(title: "Set up my plan", action: begin)
                    .accessibilityIdentifier(AccessibilityID.onboardingBegin)
                Label("Training video is never uploaded", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(TraceTheme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, wide ? 0 : 12)
            .background(TraceTheme.paper)
            .offset(y: wide ? 24 : 0)
        }
        .ignoresSafeArea(.container, edges: wide ? .bottom : [])
        .padding(.bottom, wide ? 8 : 0)
        .background(TraceTheme.paper)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .testIdentifier(AccessibilityID.onboardingWelcome)
    }

    /// Deliberately labelled example, independent of the motion engine and the user's records.
    private var demo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Squat demo")
                .font(.headline)
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(verbatim: "08")
                    .font(TraceTheme.numeral(repSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("reps")
                    .font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trace
                .frame(height: 48)
            Text("Count on-device · Track depth and tempo")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TraceTheme.cobalt, in: .rect(cornerRadius: 32))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Squat demo: 8 reps. Example movement trace.")
    }

    private var trace: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height * 0.65))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: geometry.size.height * 0.65))
                }
                .stroke(TraceTheme.sky, style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                TraceRepWave(reps: 3)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .padding(.bottom, 6)
                ForEach(0..<3) { rep in
                    Circle().fill(TraceTheme.sky)
                        .frame(width: 12, height: 12)
                        .position(x: geometry.size.width * (CGFloat(rep) + 0.585) / 3, y: geometry.size.height - 6)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
