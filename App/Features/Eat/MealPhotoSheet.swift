import AppLogic
import CoachKit
import Domain
import PhotosUI
import SwiftUI

/// The meal photo flow: a photo, Muse's estimate of what is on the plate, a USDA lookup per item, and one review
/// form. The photo stays in memory; only the saved meal entries reach the database.
@Observable
final class MealPhotoModel {
    enum Phase: Equatable {
        case choosing, preparing, estimating, review, noFood
        case failed(CoachFailure)
    }

    private(set) var phase = Phase.choosing
    private(set) var thumbnail: UIImage?
    private(set) var items: MealItemsModel?
    private(set) var saw: WhatMuseSaw?
    private(set) var notes = ""
    let consent: AIConsent

    private let environment: AppEnvironment
    private let day: LocalDay
    private let slot: MealSlot
    private var jpeg: Data?
    private var unitSystem = UnitSystem.metric
    private var work: Task<Void, Never>?

    init(context: EatAddContext) {
        environment = context.environment
        day = context.day
        slot = context.suggestedSlot
        consent = AIConsent(environment: context.environment)
    }

    func run() async {
        await consent.run()
    }

    func cancel() {
        work?.cancel()
        work = nil
    }

    /// Prepares the photo and asks Muse about it.
    func start(photo data: Data, unitSystem: UnitSystem) {
        self.unitSystem = unitSystem
        work?.cancel()
        phase = .preparing
        work = Task {
            guard let prepared = await PhotoPreparer.prepare(data) else {
                phase = .failed(CoachFailure(CoachError.invalidInput("The photo could not be read."), area: .photo))
                return
            }
            guard !Task.isCancelled else { return }
            jpeg = prepared
            thumbnail = UIImage(data: prepared)
            await estimate()
        }
    }

    func retry() {
        work?.cancel()
        work = Task { await estimate() }
    }

    func chooseAnother() {
        cancel()
        jpeg = nil
        thumbnail = nil
        items = nil
        saw = nil
        notes = ""
        phase = .choosing
    }

    private func estimate() async {
        guard let jpeg else { return }
        guard let coach = environment.coach else {
            phase = .failed(CoachFailure(CoachError.unavailable(retryAfter: nil), area: .photo))
            return
        }
        // CoachKit does not check consent: this is the check, right before the photo leaves the phone.
        guard await consent.isGranted() else {
            phase = .choosing
            return
        }
        phase = .estimating
        do {
            let input = MealPhotoInput(jpeg: jpeg, subjectID: day.string, unitSystem: unitSystem)
            let result = try await coach.estimateMeal(input, locale: .app)
            guard !Task.isCancelled else { return }
            saw = result.whatMuseSaw
            notes = result.output.notes
            guard !result.output.items.isEmpty else {
                phase = .noFood
                return
            }
            let model = MealItemsModel(
                drafts: result.output.items.map(Self.draft),
                slot: slot, day: day, source: .photo, environment: environment
            )
            items = model
            phase = .review
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(CoachFailure(error, area: .photo))
        }
    }

    private static func draft(for item: MealEstimate.Item) -> MealDraft {
        let draft = MealDraft(slot: .snack)
        draft.name = item.name
        draft.gramsText = NumberInput.text(item.gramsEstimate)
        draft.query = item.usdaQuery
        draft.lookup = .pending
        draft.confidence = item.confidence
        return draft
    }
}

struct MealPhotoSheet: View {
    let context: EatAddContext
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(UserSession.self) private var session
    @State private var model: MealPhotoModel
    @State private var pickerItem: PhotosPickerItem?
    @State private var isShowingCamera = false
    @State private var isShowingSaw = false

    init(context: EatAddContext, onSaved: @escaping () -> Void) {
        self.context = context
        self.onSaved = onSaved
        _model = State(initialValue: MealPhotoModel(context: context))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Meal photo")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier(AccessibilityID.photoClose)
                    }
                    if model.phase == .review, let items = model.items {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(role: .confirm) {
                                Task {
                                    if await items.save(using: context.log) { onSaved() }
                                }
                            }
                            .disabled(!items.canSave)
                            .accessibilityIdentifier(AccessibilityID.photoSave)
                        }
                    }
                }
        }
        .task { await model.run() }
        .onDisappear { model.cancel() }
        .task(id: pickerItem) {
            // Cancelled with the sheet, so a photo still loading when it closes is never sent.
            guard let item = pickerItem else { return }
            if let data = try? await item.loadTransferable(type: Data.self), !Task.isCancelled {
                model.start(photo: data, unitSystem: session.unitSystem)
            }
            pickerItem = nil
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraCapture { data in
                isShowingCamera = false
                model.start(photo: data, unitSystem: session.unitSystem)
            } onCancel: {
                isShowingCamera = false
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingSaw) {
            if let saw = model.saw {
                MuseSawView(saw: saw, thumbnail: model.thumbnail)
            }
        }
        .testIdentifier(AccessibilityID.mealPhoto)
    }

    // MARK: Phases

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .choosing:
            choosing
        case .preparing, .estimating:
            estimating
        case .review:
            if let items = model.items {
                MealItemsForm(model: items) { reviewHeader }
                    .task { await items.lookUpPending() }
            }
        case .noFood:
            ContentUnavailableView {
                Label("No food found", systemImage: "fork.knife")
                    .accessibilityIdentifier(AccessibilityID.photoNoFood)
            } description: {
                if !model.notes.isEmpty { Text(model.notes) }
            } actions: {
                Button("Choose Another Photo") { model.chooseAnother() }
            }
        case .failed(let failure):
            ContentUnavailableView {
                Label(failure.message, systemImage: failure.kind.systemImage)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier(AccessibilityID.photoError)
            } actions: {
                if failure.isRetryable {
                    Button("Try Again") { model.retry() }
                        .accessibilityIdentifier(AccessibilityID.photoRetry)
                }
                // A photo Muse declined or that could not be read needs another one; only a spent budget leaves
                // nothing to try.
                if failure.kind != .budget {
                    Button("Choose Another Photo") { model.chooseAnother() }
                }
            }
        }
    }

    private var choosing: some View {
        ScrollView {
            VStack(spacing: 16) {
                StubBadge()
                switch model.consent.isOn {
                case .none:
                    EmptyView()
                case .some(false):
                    CoachConsentCard(consent: model.consent)
                case .some(true):
                    VStack(spacing: 12) {
                        if CameraCapture.isAvailable {
                            Button {
                                isShowingCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier(AccessibilityID.photoCamera)
                        }
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("Choose Photo", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(AccessibilityID.photoChoose)
                        #if DEBUG
                        if context.environment.launch.mealPhotoSample {
                            Button {
                                if let data = SamplePhoto.jpegData() {
                                    model.start(photo: data, unitSystem: session.unitSystem)
                                }
                            } label: {
                                Label { Text(verbatim: "Sample photo") } icon: { Image(systemName: "wrench.and.screwdriver") }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(AccessibilityID.photoSample)
                        }
                        #endif
                    }
                    .controlSize(.large)
                    .frame(maxWidth: 480)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var estimating: some View {
        VStack(spacing: 20) {
            if let thumbnail = model.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 260)
                    .clipShape(.rect(cornerRadius: 20))
                    .accessibilityHidden(true)
            }
            ProgressView()
                .controlSize(.large)
            Text("Estimating your meal")
                .font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.photoEstimating)
    }

    @ViewBuilder
    private var reviewHeader: some View {
        Section {
            if let thumbnail = model.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(.rect(cornerRadius: 16))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .accessibilityHidden(true)
                    .accessibilityIdentifier(AccessibilityID.photoThumbnail)
            }
            if !model.notes.isEmpty {
                Text(model.notes)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if model.saw != nil {
                Button("What Muse saw") { isShowingSaw = true }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(AccessibilityID.photoSaw)
            }
        }
        if context.environment.coachIsStub {
            Section { StubBadge() }
                .listRowBackground(Color.clear)
        }
    }
}

// MARK: - What Muse saw

/// What left the phone for this estimate: the photo, the words sent with it, and how it was asked.
private struct MuseSawView: View {
    let saw: WhatMuseSaw
    let thumbnail: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let thumbnail {
                    Section("Photo") {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: 220)
                            .clipShape(.rect(cornerRadius: 12))
                            .accessibilityHidden(true)
                        ForEach(saw.images, id: \.role) { image in
                            LabeledContent {
                                Text(Int64(image.byteCount), format: .byteCount(style: .file))
                                    .monospacedDigit()
                            } label: {
                                Text(image.description)
                            }
                        }
                    }
                }
                Section("Words sent") {
                    Text(saw.input.canonicalString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                Section("Request") {
                    LabeledContent("Model", value: saw.model)
                    LabeledContent("Language", value: saw.locale)
                }
            }
            .navigationTitle("What Muse saw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
