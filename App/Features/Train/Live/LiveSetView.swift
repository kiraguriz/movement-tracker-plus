import Domain
import MotionCore
import SwiftUI

/// The full-screen set: the camera island with the engine's numbers over it.
///
/// Layout follows the window, not the device: a tall window stacks the controls, a wide one (landscape, the
/// iPhone Duo's inner display) puts the counter and the buttons at the sides and keeps the middle clear for
/// the person.
struct LiveSetView: View {
    let model: LiveSetModel
    let onEnd: () -> Void
    let onClose: () -> Void
    let onLogByHand: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingClose = false
    @ScaledMetric(relativeTo: .largeTitle) private var counterSize = 270.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.stage {
            case .preparing, .running:
                live
            case .cameraDenied:
                unavailable(
                    "Camera access is off", message: String(localized: "Reps are counted from the camera, on this phone."),
                    identifier: AccessibilityID.liveCameraDenied
                ) {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Text("Open Settings")
                            .font(.title3.weight(.bold))
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(TraceTheme.cobalt)
                    .accessibilityIdentifier(AccessibilityID.liveOpenSettings)
                }
            case .cameraRestricted:
                unavailable(
                    "The camera is restricted on this device", identifier: AccessibilityID.liveCameraRestricted
                ) { EmptyView() }
            case .failed(let message):
                unavailable("Can’t start the camera", message: message, identifier: nil) {
                    EmptyView()
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.recheckPermission() } }
        }
        .onChange(of: model.reps) { _, reps in
            AccessibilityNotification.Announcement("\(reps)").post()
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.reps)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: model.partials)
        .sensoryFeedback(.warning, trigger: model.cueCount)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .confirmationDialog("Close this set?", isPresented: $isConfirmingClose, titleVisibility: .visible) {
            Button("Close Set", action: onClose)
                .accessibilityIdentifier("live.close.confirm")
            Button("Keep Counting", role: .cancel) {}
        }
        .testIdentifier(AccessibilityID.liveSet)
    }

    // MARK: Live

    private var live: some View {
        GeometryReader { proxy in
            if proxy.size.width > 900, proxy.size.width > proxy.size.height {
                bookLayout(size: proxy.size)
            } else {
                ZStack {
                    CameraIsland(model: model).ignoresSafeArea()
                    LinearGradient(colors: [.black.opacity(0.12), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    if proxy.size.width > proxy.size.height * 1.15 {
                        wideLayout(height: proxy.size.height)
                    } else {
                        tallLayout(height: proxy.size.height)
                    }
                }
            }
        }
        .overlay {
            if model.stage == .preparing { ProgressView().controlSize(.large).tint(.white) }
        }
        // The controls sit over the camera picture, which must stay mostly clear for the person; the screens that
        // only explain why there is no camera scale with the text size like any other screen.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func tallLayout(height: CGFloat) -> some View {
        VStack(spacing: 12) {
            GlassEffectContainer(spacing: 8) {
                CentredBar(spacing: 12) {
                    closeButton
                    title
                    sideButtons()
                }
            }
            hud
            prompts
            Spacer(minLength: 0)
            counter(size: min(counterSize, height * 0.36))
                .frame(maxWidth: .infinity, alignment: .leading)
            LiveMotionTrace(signal: model.signal).frame(height: 96)
            endButton(height: 60)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Landscape on a phone, or the Duo's outer display folded into a tent: the person stands in the left of the
    /// picture, the count sits beside them and the trace runs the full width under both.
    private func wideLayout(height: CGFloat) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    if height >= 500 { title }
                    prompts
                    Spacer(minLength: 0)
                    counter(size: min(counterSize, height * 0.4), chipBeside: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 10) {
                    closeButton
                    sideButtons(vertical: true)
                    Spacer(minLength: 0)
                    hud
                }
            }
            LiveMotionTrace(signal: model.signal).frame(height: 76)
            endButton(height: 48)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The Duo opened like a book: the camera fills the left page and stops at the fold, the numbers take the right
    /// page, and nothing sits across the hinge.
    private func bookLayout(size: CGSize) -> some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CameraIsland(model: model).ignoresSafeArea()
                title.padding(16)
            }
            .frame(width: size.width * 0.48)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 18) {
                    hud
                    prompts
                    Spacer(minLength: 0)
                    counter(size: min(counterSize, size.height * 0.4), chipBeside: true)
                    LiveMotionTrace(signal: model.signal).frame(height: 88)
                    endButton(height: 60)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 10) {
                    closeButton
                    sideButtons(vertical: true)
                }
            }
            .padding(.leading, 36)
            .padding(.trailing, 16)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(TraceTheme.night)
        }
    }

    // MARK: Pieces

    private var title: some View {
        Text(ExerciseNames.name(of: model.exercise))
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .glassEffect(.regular, in: .capsule)
    }

    private var closeButton: some View {
        Button {
            if model.reps > 0 || model.partials > 0 {
                isConfirmingClose = true
            } else {
                onClose()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Close")
        .accessibilityIdentifier(AccessibilityID.liveClose)
    }

    private func sideButtons(vertical: Bool = false) -> some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return layout {
            if model.isRecording {
                Image(systemName: "record.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(width: 48, height: 48)
                    .accessibilityLabel("Recording poses")
                    .accessibilityIdentifier(AccessibilityID.liveRecording)
            }
            if model.canSwitchCamera {
                Button {
                    Task { await model.switchCamera() }
                } label: {
                    Image(systemName: "camera.rotate")
                        .font(.title3.weight(.semibold))
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("Switch camera")
                .accessibilityIdentifier(AccessibilityID.liveSwitchCamera)
            }
        }
    }

    /// What the banner under the title says, if anything: the framing the engine still needs, else the latest
    /// cue, else the idle prompt. One banner is one view whose text changes in place, so two prompts are never
    /// readable at the same time, not even while one replaces the other.
    private var prompt: Prompt? {
        guard model.stage == .running else { return nil }
        if !model.framing.isReady {
            return Prompt(
                text: LiveText.framing(model.framing), symbol: model.framing.symbolName, tint: TraceTheme.sky,
                identifier: AccessibilityID.liveFraming
            )
        }
        if let cue = model.cue {
            return Prompt(text: cue.text, symbol: "speaker.wave.2.fill", tint: TraceTheme.amber, identifier: AccessibilityID.liveCue)
        }
        if model.isIdle {
            return Prompt(
                text: String(localized: "Done? Tap End set."), symbol: "checkmark.circle", tint: TraceTheme.sky,
                identifier: AccessibilityID.liveIdle
            )
        }
        return nil
    }

    private struct Prompt: Equatable {
        let text: String
        let symbol: String
        let tint: Color
        let identifier: String
    }

    private var prompts: some View {
        VStack(spacing: 8) {
            if let notice = model.notice {
                banner(notice, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
                    .accessibilityIdentifier(AccessibilityID.liveNotice)
            }
            if let prompt {
                banner(prompt.text, systemImage: prompt.symbol, tint: prompt.tint)
                    .accessibilityIdentifier(prompt.identifier)
            }
        }
        // Only the banner coming and going is animated. One prompt replacing another is a plain swap: a cross-fade
        // would show both texts at once for a moment.
        .animation(TraceMotion.cue, value: prompt != nil)
        .animation(TraceMotion.cue, value: model.notice != nil)
        .frame(maxWidth: 560)
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(TraceTheme.night)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .contentTransition(.identity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(tint, in: .capsule)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private func counter(size: CGFloat, chipBeside: Bool = false) -> some View {
        let layout = chipBeside
            ? AnyLayout(HStackLayout(alignment: .lastTextBaseline, spacing: 16))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
        return layout {
            Text(model.reps, format: .number)
                .font(TraceTheme.numeral(size))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .animation(TraceMotion.count, value: model.reps)
                .accessibilityLabel("Reps")
                .accessibilityValue("\(model.reps)")
                .accessibilityIdentifier(AccessibilityID.liveRepCount)
            if model.partials > 0 {
                HStack(spacing: 8) {
                    TraceMark(status: .partial)
                    Text("\(model.partials) partial")
                }
                    .font(.headline)
                    .foregroundStyle(TraceTheme.amber)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.4), in: .capsule)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(AccessibilityID.livePartials)
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        #if DEBUG
        .onLongPressGesture { model.showsHUD.toggle() }
        #endif
    }

    private func endButton(height: CGFloat) -> some View {
        Button(action: onEnd) {
            Text("End set")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: height)
        }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(TraceTheme.cobalt).interactive(), in: .capsule)
            .accessibilityIdentifier(AccessibilityID.liveEnd)
    }

    @ViewBuilder
    private var hud: some View {
        #if DEBUG
        if model.showsHUD {
            LiveDebugHUD(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }

    // MARK: Unavailable

    /// No camera picture: a faded trace where the reps would be drawn, why, and the ways on — Settings when it
    /// can help, and logging the set by hand, which always can.
    private func unavailable<Actions: View>(
        _ title: LocalizedStringKey,
        message: String? = nil,
        identifier: String?,
        @ViewBuilder actions: @escaping () -> Actions
    ) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        closeButton
                        Spacer(minLength: 12)
                        Text(ExerciseNames.name(of: model.exercise))
                            .font(.headline)
                            .lineLimit(1)
                            .padding(.horizontal, 20)
                            .frame(minHeight: 48)
                            .glassEffect(.regular, in: .capsule)
                        Spacer(minLength: 12)
                        Color.clear.frame(width: 48, height: 48)
                    }
                    FadedTrace()
                        .stroke(.white.opacity(0.22), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(height: 150)
                        .overlay(alignment: .bottom) {
                            Line()
                                .stroke(TraceTheme.sky.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [4, 5]))
                                .frame(height: 1)
                                .padding(.horizontal, -16)
                        }
                        .padding(.vertical, 40)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "video.slash")
                            .font(.title.weight(.medium))
                            .foregroundStyle(TraceTheme.amber)
                            .frame(width: 64, height: 64)
                            .background(TraceTheme.amber.opacity(0.16), in: .circle)
                            .accessibilityHidden(true)
                        Text(title)
                            .font(.title.bold())
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier(identifier ?? AccessibilityID.liveNotice)
                        if let message {
                            Text(message)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    Spacer(minLength: 24)
                    VStack(spacing: 10) {
                        actions()
                        Button(action: onLogByHand) {
                            Text("Log this set by hand")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 56)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier(AccessibilityID.liveLogByHand)
                    }
                }
                .foregroundStyle(.white)
                .frame(minHeight: max(0, geometry.size.height - 32))
                .padding(16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// Three views in a row: the first and last hug the edges and the middle one stays on the row's centre line,
/// as wide as the wider side leaves room for, whichever side holds more buttons.
private struct CentredBar: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let inset = sideInset(subviews)
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? 2 * inset + subviews[1].sizeThatFits(.unspecified).width
        let middle = subviews[1].sizeThatFits(ProposedViewSize(width: max(0, width - 2 * inset), height: nil))
        let sides = max(subviews[0].sizeThatFits(.unspecified).height, subviews[2].sizeThatFits(.unspecified).height)
        return CGSize(width: width, height: max(sides, middle.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let inset = sideInset(subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(width: max(0, bounds.width - 2 * inset), height: nil)
        )
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }

    /// The room kept clear on each side of the middle view: the wider side and the gap after it.
    private func sideInset(_ subviews: Subviews) -> CGFloat {
        max(subviews[0].sizeThatFits(.unspecified).width, subviews[2].sizeThatFits(.unspecified).width) + spacing
    }
}

/// One rep drawn, then dots where the next ones would be: the trace waiting for the camera.
private struct FadedTrace: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, top = rect.minY, bottom = rect.maxY
        path.move(to: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: w * 0.15, y: top))
        path.addCurve(to: CGPoint(x: w * 0.32, y: bottom), control1: CGPoint(x: w * 0.22, y: top), control2: CGPoint(x: w * 0.23, y: bottom))
        path.addCurve(to: CGPoint(x: w * 0.5, y: top), control1: CGPoint(x: w * 0.42, y: bottom), control2: CGPoint(x: w * 0.42, y: top))
        var x = w * 0.5
        while x < w {
            x += 10
            path.move(to: CGPoint(x: x, y: top))
            path.addLine(to: CGPoint(x: x + 0.5, y: top))
        }
        return path
    }
}

private struct Line: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) }
    }
}
