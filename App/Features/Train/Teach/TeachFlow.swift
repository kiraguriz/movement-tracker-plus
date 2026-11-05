import AppLogic
import Domain
import MotionCore
import PoseCapture
import SwiftUI

/// Teaching the app a new exercise, full screen: a name, the camera for the demonstration, the count, the
/// replay check and saving. Presented over the exercise picker.
struct TeachFlow: View {
    let initialName: String
    /// The exercise to put in the workout (a taught one just saved, or one the user already had).
    let onAdd: (Exercise) -> Void
    let onClose: () -> Void

    @Environment(\.appEnvironment) private var environment
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: TeachModel?
    @State private var isConfirmingDiscard = false

    var body: some View {
        ZStack {
            if let model {
                content(model)
            }
        }
        .task {
            guard model == nil else { return }
            let created = TeachModel(environment: environment, name: initialName)
            model = created
            await created.loadCatalog()
        }
        .onDisappear {
            let finished = model
            Task { await finished?.stop() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, let model { Task { await model.recheckPermission() } }
        }
        .testIdentifier(AccessibilityID.teachFlow)
    }

    @ViewBuilder
    private func content(_ model: TeachModel) -> some View {
        ZStack {
            switch model.step {
            case .name:
                paper { NameStep(model: model, close: close, onAdd: onAdd) }
            case .framing, .countdown, .recording, .studying:
                CameraStep(model: model, close: close)
            case .confirm:
                paper { ConfirmStep(model: model, close: close) }
            case .verified, .manual:
                paper { SaveStep(model: model, close: close) }
            case .failed(let problem):
                paper { FailedStep(model: model, problem: problem, close: close) }
            case .saved:
                paper { SavedStep(model: model, onAdd: onAdd, onClose: onClose) }
            }
        }
        .animation(TraceMotion.screen, value: model.step)
        .confirmationDialog("teach.discard.title", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
            Button("teach.discard.confirm", role: .destructive, action: onClose)
                .accessibilityIdentifier(AccessibilityID.teachDiscard)
            Button("teach.discard.keep", role: .cancel) {}
        }
        .errorAlert(Binding(get: { model.errorMessage }, set: { model.errorMessage = $0 }))
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func close() {
        guard let model else {
            onClose()
            return
        }
        switch model.step {
        case .confirm, .verified, .manual, .failed:
            isConfirmingDiscard = true
        default:
            onClose()
        }
    }

    private func paper<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ZStack {
            TraceTheme.paper.ignoresSafeArea()
            content()
        }
    }
}

// MARK: - Shared pieces

private struct CloseButton: View {
    let action: () -> Void
    var onCamera = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(onCamera ? Color.white : TraceTheme.ink)
                .frame(width: 48, height: 48)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Close")
        .accessibilityIdentifier(AccessibilityID.teachClose)
    }
}

private struct StepHeader: View {
    let close: () -> Void

    var body: some View {
        HStack {
            CloseButton(action: close)
            Spacer(minLength: 0)
        }
    }
}

/// The scrolling body of a paper step with its button pinned under it.
private struct PaperStep<Body: View, Footer: View>: View {
    let close: () -> Void
    @ViewBuilder var content: Body
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            StepHeader(close: close)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 0) {
                footer
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Name

private struct NameStep: View {
    @Bindable var model: TeachModel
    let close: () -> Void
    let onAdd: (Exercise) -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        PaperStep(close: close) {
            Text("teach.title")
                .font(.largeTitle.bold())
                .foregroundStyle(TraceTheme.ink)
                .accessibilityAddTraits(.isHeader)
            TextField("teach.name.field", text: $model.name)
                .font(.title2.weight(.semibold))
                .textInputAutocapitalization(.words)
                .submitLabel(.continue)
                .focused($isFocused)
                .padding(.horizontal, 20)
                .frame(minHeight: 64)
                .background(TraceTheme.card, in: .rect(cornerRadius: 24))
                .onChange(of: model.name) { _, value in
                    if value.count > TaughtExercise.maxNameLength {
                        model.name = String(value.prefix(TaughtExercise.maxNameLength))
                    }
                }
                .onSubmit(model.continueFromName)
                .accessibilityIdentifier(AccessibilityID.teachName)
            if let existing = model.existingExercise {
                HStack(spacing: 12) {
                    Text("teach.name.exists")
                        .foregroundStyle(TraceTheme.secondary)
                        .accessibilityIdentifier(AccessibilityID.teachNameExists)
                    Spacer(minLength: 8)
                    Button("teach.addToWorkout") { onAdd(existing) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .accessibilityIdentifier(AccessibilityID.teachNameAdd)
                }
            }
        } footer: {
            PrimaryButton(title: "Continue", isEnabled: model.validName != nil && model.existingExercise == nil) {
                isFocused = false
                model.continueFromName()
            }
            .accessibilityIdentifier(AccessibilityID.teachNameContinue)
        }
        .onAppear { isFocused = true }
    }
}

// MARK: - Camera

private struct CameraStep: View {
    let model: TeachModel
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.stage {
            case .preparing, .running:
                live
            case .cameraDenied:
                unavailable("Camera access is off", identifier: AccessibilityID.teachCameraDenied) {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Text("Open Settings")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(TraceTheme.cobalt)
                }
            case .cameraRestricted:
                unavailable("The camera is restricted on this device", identifier: nil) { EmptyView() }
            case .failed(let message):
                unavailable("Can’t start the camera", message: message, identifier: nil) { EmptyView() }
            }
        }
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.repsSeen)
        .sensoryFeedback(.selection, trigger: model.countdown)
    }

    private var live: some View {
        ZStack {
            TeachCameraIsland(model: model).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.12), .clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    CloseButton(action: close, onCamera: true)
                    Spacer(minLength: 0)
                    if model.canSwitchCamera, model.step == .framing {
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
                        .accessibilityIdentifier(AccessibilityID.teachSwitchCamera)
                    }
                }
                if let notice = model.notice {
                    banner(notice, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
                }
                if model.step == .framing, model.stage == .running {
                    if model.framing.isReady {
                        banner(LocalizedStringKey("teach.startHint"), systemImage: "figure.stand", tint: TraceTheme.sky)
                            .accessibilityIdentifier(AccessibilityID.teachFraming)
                    } else {
                        banner(LiveText.framing(model.framing), systemImage: model.framing.symbolName, tint: TraceTheme.sky)
                            .accessibilityIdentifier(AccessibilityID.teachFraming)
                    }
                }
                Spacer(minLength: 0)
                bottom
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: 560)
        }
        .overlay {
            if model.stage == .preparing { ProgressView().controlSize(.large).tint(.white) }
        }
    }

    @ViewBuilder
    private var bottom: some View {
        switch model.step {
        case .framing:
            Button(action: model.start) {
                Text("teach.start")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .glassEffect(.regular.tint(TraceTheme.cobalt).interactive(), in: .capsule)
            .disabled(!(model.stage == .running && model.framing.isReady))
            .opacity(model.stage == .running && model.framing.isReady ? 1 : 0.4)
            .accessibilityIdentifier(AccessibilityID.teachStart)
        case .countdown:
            Text(model.countdown, format: .number)
                .font(TraceTheme.numeral(200))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
                .contentTransition(.numericText(countsDown: true))
                .animation(TraceMotion.count, value: model.countdown)
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .accessibilityIdentifier(AccessibilityID.teachCountdown)
        case .recording:
            VStack(spacing: 20) {
                RepDots(count: model.repsSeen)
                Button(action: model.finishRecording) {
                    Text("teach.rec.done")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .glassEffect(.regular.tint(TraceTheme.cobalt).interactive(), in: .capsule)
                .accessibilityIdentifier(AccessibilityID.teachDone)
            }
        case .studying:
            ProgressView().controlSize(.large).tint(.white).frame(height: 56)
        default:
            EmptyView()
        }
    }

    private func banner(_ text: LocalizedStringKey, systemImage: String, tint: Color) -> some View {
        bannerLabel(Text(text), systemImage: systemImage, tint: tint)
    }

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        bannerLabel(Text(verbatim: text), systemImage: systemImage, tint: tint)
    }

    private func bannerLabel(_ text: Text, systemImage: String, tint: Color) -> some View {
        Label { text } icon: { Image(systemName: systemImage) }
            .font(.title3.weight(.semibold))
            .foregroundStyle(TraceTheme.night)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .contentTransition(.identity)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(tint, in: .capsule)
    }

    private func unavailable<Actions: View>(
        _ title: LocalizedStringKey, message: String? = nil, identifier: String?,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CloseButton(action: close, onCamera: true)
                Spacer(minLength: 0)
            }
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
                    .accessibilityIdentifier(identifier ?? "teach.camera.unavailable")
                if let message {
                    Text(verbatim: message).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 24)
            actions()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: 560)
    }
}

/// One dot per rep seen so far, at least three places so the goal is visible from the start.
private struct RepDots: View {
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            ForEach(0..<max(TeachModel.repsAsked, count), id: \.self) { index in
                Circle()
                    .fill(index < count ? Color.white : Color.white.opacity(0.28))
                    .frame(width: 22, height: 22)
            }
        }
        .animation(TraceMotion.count, value: count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("teach.rec.dots.a11y \(count)")
        .accessibilityIdentifier(AccessibilityID.teachDots)
        .accessibilityValue("\(count)")
    }
}

// MARK: - Confirm

private struct ConfirmStep: View {
    @Bindable var model: TeachModel
    let close: () -> Void

    var body: some View {
        PaperStep(close: close) {
            Text("teach.count.q")
                .font(.largeTitle.bold())
                .foregroundStyle(TraceTheme.ink)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 24) {
                stepper("minus", label: "One rep fewer", id: AccessibilityID.teachFewer, enabled: model.confirmedReps > TeachModel.repRange.lowerBound) {
                    model.confirmedReps -= 1
                }
                Text(model.confirmedReps, format: .number)
                    .font(TraceTheme.numeral(160))
                    .foregroundStyle(TraceTheme.ink)
                    .contentTransition(.numericText())
                    .animation(TraceMotion.count, value: model.confirmedReps)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Reps")
                    .accessibilityValue("\(model.confirmedReps)")
                    .accessibilityIdentifier(AccessibilityID.teachRepCount)
                stepper("plus", label: "One rep more", id: AccessibilityID.teachMore, enabled: model.confirmedReps < TeachModel.repRange.upperBound) {
                    model.confirmedReps += 1
                }
            }
            .frame(maxWidth: .infinity)
        } footer: {
            PrimaryButton(title: "Continue", isBusy: model.isWorking) { model.confirm() }
                .accessibilityIdentifier(AccessibilityID.teachConfirm)
        }
        .sensoryFeedback(.selection, trigger: model.confirmedReps)
    }

    private func stepper(
        _ symbol: String, label: LocalizedStringKey, id: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.bold))
                .foregroundStyle(TraceTheme.ink)
                .frame(width: 56, height: 56)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

// MARK: - Save

private struct SaveStep: View {
    @Bindable var model: TeachModel
    let close: () -> Void

    var body: some View {
        PaperStep(close: close) {
            Text(verbatim: model.name)
                .font(.largeTitle.bold())
                .foregroundStyle(TraceTheme.ink)
                .accessibilityAddTraits(.isHeader)
            if model.step == .verified {
                verified
                TeachFormChecksSection(checks: model.formChecks)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("teach.muscles")
                    .font(.headline)
                    .foregroundStyle(TraceTheme.ink)
                MuscleChips(selection: $model.muscles)
            }
            HStack {
                Text("teach.equipment")
                    .font(.headline)
                    .foregroundStyle(TraceTheme.ink)
                Spacer(minLength: 8)
                Picker("teach.equipment", selection: $model.equipment) {
                    ForEach(Equipment.allCases, id: \.self) { equipment in
                        Text(verbatim: TeachText.string("equipment.\(equipment.rawValue)")).tag(equipment)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityLabel("teach.equipment")
                .accessibilityIdentifier(AccessibilityID.teachEquipment)
            }
            .frame(minHeight: 44)
        } footer: {
            PrimaryButton(title: "Save", isEnabled: model.canSave, isBusy: model.isWorking) { model.save() }
                .accessibilityIdentifier(AccessibilityID.teachSave)
        }
        .testIdentifier(model.step == .verified ? AccessibilityID.teachVerified : AccessibilityID.teachManual)
    }

    private var verified: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if let top = model.topFrame {
                    PoseThumbnail(frame: top).accessibilityLabel("teach.pose.start")
                }
                if let bottom = model.bottomFrame {
                    PoseThumbnail(frame: bottom).accessibilityLabel("teach.pose.end")
                }
            }
            .frame(height: 150)
            Label {
                Text("teach.verify.pass \(model.countedReps) \(model.confirmedReps)")
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.headline)
            .foregroundStyle(TraceTheme.blue)
        }
    }
}

private struct MuscleChips: View {
    @Binding var selection: Set<MuscleGroup>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(MuscleGroup.allCases, id: \.self) { muscle in
                let isOn = selection.contains(muscle)
                Button {
                    if isOn { selection.remove(muscle) } else { selection.insert(muscle) }
                } label: {
                    Text(verbatim: TeachText.string("muscle.\(muscle.rawValue)"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(isOn ? TraceTheme.paper : TraceTheme.ink)
                .background(isOn ? TraceTheme.ink : TraceTheme.card, in: .capsule)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
                .accessibilityIdentifier(AccessibilityID.teachMuscle(muscle))
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// A pose drawn as a skeleton, scaled to fill its card.
private struct PoseThumbnail: View {
    let frame: PoseFrame

    var body: some View {
        Canvas { context, size in
            let points = frame.joints.filter { $0.value.confidence >= 0.3 }
            guard !points.isEmpty else { return }
            let xs = points.values.map { $0.x * frame.imageAspect }
            let ys = points.values.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return }
            let inset = 24.0
            let width = max(maxX - minX, 0.05)
            let height = max(maxY - minY, 0.05)
            let scale = min((size.width - 2 * inset) / width, (size.height - 2 * inset) / height)
            let offsetX = (size.width - width * scale) / 2
            let offsetY = (size.height - height * scale) / 2
            func place(_ joint: Joint) -> CGPoint? {
                guard let point = points[joint] else { return nil }
                return CGPoint(
                    x: offsetX + (point.x * frame.imageAspect - minX) * scale,
                    y: offsetY + (maxY - point.y) * scale
                )
            }
            var bones = Path()
            for bone in Skeleton.bones {
                guard let from = place(bone.from), let to = place(bone.to) else { continue }
                bones.move(to: from)
                bones.addLine(to: to)
            }
            context.stroke(bones, with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            for joint in points.keys {
                guard let point = place(joint) else { continue }
                context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(TraceTheme.sky))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TraceTheme.night, in: .rect(cornerRadius: 24))
    }
}

// MARK: - Failed

private struct FailedStep: View {
    let model: TeachModel
    let problem: TeachProblem
    let close: () -> Void

    var body: some View {
        PaperStep(close: close) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title.weight(.medium))
                .foregroundStyle(TraceTheme.amberInk)
                .frame(width: 64, height: 64)
                .background(TraceTheme.amber.opacity(0.16), in: .circle)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.title2.weight(.semibold))
                .foregroundStyle(TraceTheme.ink)
                .accessibilityIdentifier(AccessibilityID.teachFailed)
        } footer: {
            VStack(spacing: 0) {
                PrimaryButton(title: "Try again") { model.retry() }
                    .accessibilityIdentifier(AccessibilityID.teachRetry)
                if model.failures >= TeachModel.attemptsBeforeManual {
                    Button(action: model.chooseManual) {
                        Text("teach.fail.manual")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier(AccessibilityID.teachManual + ".choose")
                }
            }
        }
    }

    private var message: String {
        switch problem {
        case .noMotion: String(localized: "teach.fail.noMotion")
        case .tooFew(let found): String(localized: "teach.fail.tooFew \(found)")
        case .mismatch(let counted, let expected): String(localized: "teach.fail.mismatch \(counted) \(expected)")
        case .partial: String(localized: "teach.fail.partial")
        case .small: String(localized: "teach.fail.small")
        case .uneven: String(localized: "teach.fail.uneven")
        case .hidden: String(localized: "teach.fail.hidden")
        }
    }
}

// MARK: - Saved

private struct SavedStep: View {
    let model: TeachModel
    let onAdd: (Exercise) -> Void
    let onClose: () -> Void

    var body: some View {
        PaperStep(close: onClose) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(TraceTheme.blue)
                .accessibilityHidden(true)
            Text(verbatim: model.name)
                .font(.largeTitle.bold())
                .foregroundStyle(TraceTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AccessibilityID.teachSaved)
        } footer: {
            VStack(spacing: 0) {
                if let exercise = model.savedExercise {
                    PrimaryButton(title: "teach.addToWorkout") { onAdd(exercise) }
                        .accessibilityIdentifier(AccessibilityID.teachAddToWorkout)
                }
                Button(action: onClose) {
                    Text("Done")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
                .accessibilityIdentifier(AccessibilityID.teachFinish)
            }
        }
    }
}

// MARK: - Camera view

/// The UIKit camera island for teaching: the preview layer with the skeleton over it.
struct TeachCameraIsland: UIViewRepresentable {
    let model: TeachModel

    func makeUIView(context: Context) -> CameraIslandView {
        let view = CameraIslandView()
        model.attach(island: view)
        return view
    }

    func updateUIView(_ view: CameraIslandView, context: Context) {}

    static func dismantleUIView(_ view: CameraIslandView, coordinator: ()) {
        view.update(nil)
    }
}

/// Strings whose key is built at run time, which `Text` would look up as an interpolation.
private enum TeachText {
    static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
