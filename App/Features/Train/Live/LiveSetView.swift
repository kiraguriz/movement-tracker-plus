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

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var isConfirmingDiscard = false
    @ScaledMetric(relativeTo: .largeTitle) private var counterSize = 112.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.stage {
            case .preparing, .running:
                live
            case .cameraDenied:
                unavailable(
                    "Camera access is off", systemImage: "camera.fill", identifier: AccessibilityID.liveCameraDenied
                ) {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier(AccessibilityID.liveOpenSettings)
                }
            case .cameraRestricted:
                unavailable(
                    "The camera is restricted on this device", systemImage: "lock.fill",
                    identifier: AccessibilityID.liveCameraRestricted
                ) { EmptyView() }
            case .failed(let message):
                unavailable("Can’t start the camera", systemImage: "exclamationmark.triangle.fill", message: message, identifier: nil) {
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
        .confirmationDialog("Discard this set?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("Discard Set", role: .destructive, action: onClose)
            Button("Keep Counting", role: .cancel) {}
        }
        .testIdentifier(AccessibilityID.liveSet)
    }

    // MARK: Live

    private var live: some View {
        ZStack {
            CameraIsland(model: model)
                .ignoresSafeArea()
            GeometryReader { proxy in
                if proxy.size.width > proxy.size.height * 1.15 {
                    wideLayout
                } else {
                    tallLayout(height: proxy.size.height)
                }
            }
            if model.stage == .preparing {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
        // The controls sit over the camera picture, which must stay mostly clear for the person; the screens that
        // only explain why there is no camera scale with the text size like any other screen.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private func tallLayout(height: CGFloat) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                closeButton
                Spacer(minLength: 0)
                title
                Spacer(minLength: 0)
                sideButtons
            }
            hud
            prompts
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 16) {
                counter
                Spacer(minLength: 0)
                gauge.frame(height: min(280, max(120, height * 0.34)))
            }
            endButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var wideLayout: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                closeButton
                hud
                Spacer(minLength: 0)
                counter
            }
            VStack(spacing: 12) {
                title
                prompts
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            VStack(alignment: .trailing, spacing: 12) {
                sideButtons
                gauge.frame(maxHeight: .infinity)
                endButton.frame(width: 220)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: Pieces

    private var title: some View {
        Text(ExerciseNames.name(of: model.exercise))
            .font(.headline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 16)
            .frame(minHeight: 44)
            .glassEffect(.regular, in: .capsule)
    }

    private var closeButton: some View {
        Button {
            if model.reps > 0 || model.partials > 0 {
                isConfirmingDiscard = true
            } else {
                onClose()
            }
        } label: {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Close")
        .accessibilityIdentifier(AccessibilityID.liveClose)
    }

    private var sideButtons: some View {
        HStack(spacing: 8) {
            if model.isRecording {
                Image(systemName: "record.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
                    .accessibilityLabel("Recording poses")
                    .accessibilityIdentifier(AccessibilityID.liveRecording)
            }
            if model.canSwitchCamera {
                Button {
                    Task { await model.switchCamera() }
                } label: {
                    Image(systemName: "camera.rotate")
                        .font(.title3.weight(.semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
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
                text: LiveText.framing(model.framing), symbol: model.framing.symbolName, tint: .blue,
                identifier: AccessibilityID.liveFraming
            )
        }
        if let cue = model.cue {
            return Prompt(text: cue.text, symbol: "speaker.wave.2.fill", tint: .orange, identifier: AccessibilityID.liveCue)
        }
        if model.isIdle {
            return Prompt(
                text: String(localized: "Done? Tap End set."), symbol: "checkmark.circle", tint: .green,
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
        .animation(.snappy, value: prompt != nil)
        .animation(.snappy, value: model.notice != nil)
        .frame(maxWidth: 560)
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .contentTransition(.identity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .glassEffect(.regular.tint(tint.opacity(0.35)), in: .rect(cornerRadius: 28))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    private var counter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.reps, format: .number)
                .font(.system(size: counterSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .animation(.snappy, value: model.reps)
                .accessibilityLabel("Reps")
                .accessibilityValue("\(model.reps)")
                .accessibilityIdentifier(AccessibilityID.liveRepCount)
            if model.partials > 0 {
                Label("\(model.partials) partial", systemImage: "arrow.down.to.line.compact")
                    .font(.headline)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AccessibilityID.livePartials)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        #if DEBUG
        .onLongPressGesture { model.showsHUD.toggle() }
        #endif
    }

    private var gauge: some View {
        DepthGauge(signal: model.signal)
            .accessibilityHidden(true)
    }

    private var endButton: some View {
        PrimaryButton(title: "End set", action: onEnd)
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

    private func unavailable<Actions: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        message: String? = nil,
        identifier: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                closeButton
                Spacer()
            }
            .padding(16)
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
                    .accessibilityIdentifier(identifier ?? AccessibilityID.liveNotice)
            } description: {
                if let message { Text(message) }
            } actions: {
                actions()
            }
        }
    }
}

/// A vertical bar that fills as the body goes down, with a mark where a rep starts to count.
struct DepthGauge: View {
    let signal: LiveSignal

    /// The depth, as a fraction of the calibrated range, at which the engine sees the bottom of a rep.
    private static let countingDepth = 1 - MotionConfig.default.segmenter.bottomEnter

    var body: some View {
        let depth = min(1, max(0, signal.value))
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Capsule().fill(.white.opacity(0.2))
                Capsule()
                    .fill(depth >= Self.countingDepth ? Color.green : Color.white)
                    .frame(height: proxy.size.height * depth)
                Capsule()
                    .fill(.white)
                    .frame(width: proxy.size.width + 8, height: 3)
                    .offset(y: proxy.size.height * Self.countingDepth - 1.5)
            }
        }
        .frame(width: 16)
        .shadow(color: .black.opacity(0.4), radius: 2)
    }
}
