import Domain
import Foundation

/// A progress event of a running insight, or its result.
public enum InsightEvent<Output: Codable & Sendable & Equatable>: Sendable, Equatable {
    case update(InsightUpdate)
    case finished(InsightResult<Output>)
}

/// The coach's one-shot features: set review, session debrief and meal photo, plus food search and voice
/// transcription. Every answer is cached by its input hash in the `CoachInsightStore`, decoded strictly (one retry with
/// the error, then an on-device fallback where the feature has one) and stored with the model, prompt version, token
/// usage and a "What Muse saw" record. Chat lives in `ChatService`.
public struct CoachService: Sendable {
    public let client: CoachClient
    private let runner: InsightRunner
    private let offlineStrings: any OfflineStrings

    public init(
        client: CoachClient,
        insights: any CoachInsightStore,
        ids: any IDGenerating = UUIDv7Generator.shared,
        clock: any CoachClock = SystemCoachClock(),
        offlineStrings: any OfflineStrings = BuiltInOfflineStrings()
    ) {
        self.client = client
        self.runner = InsightRunner(client: client, insights: insights, ids: ids, clock: clock)
        self.offlineStrings = offlineStrings
    }

    // MARK: Set review

    /// Reviews a set. Returns the stored answer when the same input was reviewed before (no network); otherwise asks
    /// Muse, and falls back to an on-device review marked `.offline` when Muse cannot answer. Throws only for
    /// cancellation and for input that cannot be sent at all (more than two images, an image that is not a PNG).
    public func reviewSet(
        _ input: SetReviewInput,
        locale: CoachLocale,
        onUpdate: (@Sendable (InsightUpdate) -> Void)? = nil
    ) async throws -> InsightResult<SetReview> {
        try await runner.run(try setReviewPlan(input, locale: locale), onUpdate: onUpdate)
    }

    /// The same as `reviewSet`, as a stream of updates (partial JSON as it is written) ending in `.finished`.
    public func reviewSetEvents(_ input: SetReviewInput, locale: CoachLocale) -> AsyncThrowingStream<InsightEvent<SetReview>, any Error> {
        events { onUpdate in try await reviewSet(input, locale: locale, onUpdate: onUpdate) }
    }

    /// What is stored for this input (any origin), without touching the network.
    public func storedSetReview(for input: SetReviewInput, locale: CoachLocale) async throws -> InsightResult<SetReview>? {
        await runner.stored(try setReviewPlan(input, locale: locale))
    }

    // MARK: Session debrief

    public func debriefSession(
        _ input: SessionDebriefInput,
        locale: CoachLocale,
        onUpdate: (@Sendable (InsightUpdate) -> Void)? = nil
    ) async throws -> InsightResult<SessionDebrief> {
        try await runner.run(try debriefPlan(input, locale: locale), onUpdate: onUpdate)
    }

    public func debriefSessionEvents(_ input: SessionDebriefInput, locale: CoachLocale) -> AsyncThrowingStream<InsightEvent<SessionDebrief>, any Error> {
        events { onUpdate in try await debriefSession(input, locale: locale, onUpdate: onUpdate) }
    }

    public func storedDebrief(for input: SessionDebriefInput, locale: CoachLocale) async throws -> InsightResult<SessionDebrief>? {
        await runner.stored(try debriefPlan(input, locale: locale))
    }

    // MARK: Meal photo

    /// Estimates the foods in a meal photo. Not streamed (the proxy does not allow it) and without an offline
    /// fallback: when Muse cannot answer, this throws the reason.
    public func estimateMeal(_ input: MealPhotoInput, locale: CoachLocale) async throws -> InsightResult<MealEstimate> {
        try await runner.run(try mealPlan(input, locale: locale))
    }

    // MARK: Taught exercise form checks

    /// Asks Muse which form checks fit an exercise the user taught. Only a Muse answer is a draft worth acting on:
    /// when Muse cannot answer, the result is the empty "just count" draft marked `.offline`. Throws only for
    /// cancellation and for input that cannot be sent (not two PNG drawings). Callers check consent first.
    public func authorSpec(
        _ input: SpecAuthorInput,
        locale: CoachLocale,
        onUpdate: (@Sendable (InsightUpdate) -> Void)? = nil
    ) async throws -> InsightResult<SpecDraft> {
        try await runner.run(try specAuthorPlan(input, locale: locale), onUpdate: onUpdate)
    }

    // MARK: Proxy calls

    public func searchFood(query: String, page: Int = 1) async throws -> FoodSearchPage {
        try await client.searchFood(query: query, page: page)
    }

    public func transcribe(wav: Data, locale: CoachLocale? = nil, keywords: [String] = []) async throws -> Transcription {
        try await client.transcribe(wav: wav, locale: locale, keywords: keywords)
    }

    // MARK: Plans

    func setReviewPlan(_ input: SetReviewInput, locale: CoachLocale) throws -> InsightPlan<SetReview> {
        guard input.images.count <= 2 else { throw CoachError.invalidInput("A set review takes at most two images.") }
        // What is sent, hashed and described is the picture without its metadata (see `ImageSanitizer`).
        var images: [(source: SkeletonImage, png: Data)] = []
        for image in input.images {
            guard let png = ImageSanitizer.png(image.png) else { throw CoachError.invalidInput("Skeleton images must be PNG data.") }
            images.append((image, png))
        }
        let feature = CoachFeature.setReview
        let json = input.json
        let hasImages = !images.isEmpty
        let text = "Review this set.\(hasImages ? " The attached images follow the `images` list, in order." : "")\n\nData (JSON):\n\(json.canonicalString)"
        let effort = ReasoningEffort.low
        return InsightPlan(
            kind: .setReview,
            feature: feature,
            subjectID: input.setID.rawValue,
            promptVersion: PromptVersion.setReview,
            locale: locale,
            model: .sparkLatest,
            effort: effort,
            maxOutputTokens: 5000,
            stream: true,
            developerText: Prompts.setReview(locale: locale),
            userParts: [.inputText(text)] + images.map { .inputImage(dataURL: Self.dataURL(mediaType: "image/png", $0.png)) },
            format: StructuredFormat(name: "SetReview", schema: SetReview.schema),
            saw: WhatMuseSaw(
                feature: feature.rawValue, model: MuseModel.sparkLatest.rawValue, promptVersion: PromptVersion.setReview,
                effort: effort.rawValue, locale: locale.rawValue, input: json,
                images: images.map { SawImage(role: $0.source.role.rawValue, description: $0.source.summary, mediaType: "image/png", byteCount: $0.png.count) }
            ),
            inputHash: InsightHasher.hash(
                feature: feature, promptVersion: PromptVersion.setReview, model: .sparkLatest, effort: effort, locale: locale,
                subjectID: input.setID.rawValue, input: json, images: images.map { .init(role: $0.source.role.rawValue, data: $0.png) }
            ),
            validate: { try $0.validated(for: input) },
            fallback: { [offlineStrings] in SetReview.offline(for: input, locale: locale, strings: offlineStrings) }
        )
    }

    func debriefPlan(_ input: SessionDebriefInput, locale: CoachLocale) throws -> InsightPlan<SessionDebrief> {
        guard !input.exercises.isEmpty else { throw CoachError.invalidInput("The session has no exercises to debrief.") }
        let feature = CoachFeature.debrief
        let json = input.json
        let effort = ReasoningEffort.medium
        return InsightPlan(
            kind: .sessionDebrief,
            feature: feature,
            subjectID: input.sessionID.rawValue,
            promptVersion: PromptVersion.debrief,
            locale: locale,
            model: .sparkLatest,
            effort: effort,
            maxOutputTokens: 6000,
            stream: true,
            developerText: Prompts.debrief(locale: locale),
            userParts: [.inputText("Debrief this session and suggest the next one.\n\nData (JSON):\n\(json.canonicalString)")],
            format: StructuredFormat(name: "SessionDebrief", schema: SessionDebrief.schema),
            saw: WhatMuseSaw(
                feature: feature.rawValue, model: MuseModel.sparkLatest.rawValue, promptVersion: PromptVersion.debrief,
                effort: effort.rawValue, locale: locale.rawValue, input: json, images: []
            ),
            inputHash: InsightHasher.hash(
                feature: feature, promptVersion: PromptVersion.debrief, model: .sparkLatest, effort: effort, locale: locale,
                subjectID: input.sessionID.rawValue, input: json, images: []
            ),
            validate: { try $0.validated(for: input) },
            fallback: { [offlineStrings] in SessionDebrief.offline(for: input, locale: locale, strings: offlineStrings) }
        )
    }

    func mealPlan(_ input: MealPhotoInput, locale: CoachLocale) throws -> InsightPlan<MealEstimate> {
        // The photo goes out without its EXIF (position, time, device) but keeps its orientation.
        guard let jpeg = ImageSanitizer.jpeg(input.jpeg) else { throw CoachError.invalidInput("The meal photo must be JPEG data.") }
        let feature = CoachFeature.mealPhoto
        let json = input.json
        let effort = ReasoningEffort.low
        return InsightPlan(
            kind: .mealEstimate,
            feature: feature,
            subjectID: input.subjectID,
            promptVersion: PromptVersion.mealPhoto,
            locale: locale,
            model: .sparkLatest,
            effort: effort,
            maxOutputTokens: 4000,
            stream: false,
            developerText: Prompts.mealPhoto(locale: locale),
            userParts: [.inputText("\(json.canonicalString)"), .inputImage(dataURL: Self.dataURL(mediaType: "image/jpeg", jpeg))],
            format: StructuredFormat(name: "MealEstimate", schema: MealEstimate.schema),
            saw: WhatMuseSaw(
                feature: feature.rawValue, model: MuseModel.sparkLatest.rawValue, promptVersion: PromptVersion.mealPhoto,
                effort: effort.rawValue, locale: locale.rawValue, input: json,
                images: [SawImage(role: "meal_photo", description: "Photo of a meal, as taken by the user.", mediaType: "image/jpeg", byteCount: jpeg.count)]
            ),
            inputHash: InsightHasher.hash(
                feature: feature, promptVersion: PromptVersion.mealPhoto, model: .sparkLatest, effort: effort, locale: locale,
                subjectID: input.subjectID, input: json, images: [.init(role: "meal_photo", data: jpeg)]
            ),
            validate: { try $0.validated() },
            fallback: nil
        )
    }

    func specAuthorPlan(_ input: SpecAuthorInput, locale: CoachLocale) throws -> InsightPlan<SpecDraft> {
        guard input.images.count == 2 else { throw CoachError.invalidInput("A spec draft takes exactly two drawings.") }
        var images: [(source: SkeletonImage, png: Data)] = []
        for image in input.images {
            guard let png = ImageSanitizer.png(image.png) else { throw CoachError.invalidInput("Skeleton images must be PNG data.") }
            images.append((image, png))
        }
        let feature = CoachFeature.specAuthor
        let json = input.json
        let effort = ReasoningEffort.low
        let text = "Choose the form checks for this exercise. The attached images follow the `images` list, in order.\n\nData (JSON):\n\(json.canonicalString)"
        return InsightPlan(
            kind: .specDraft,
            feature: feature,
            subjectID: input.exerciseID.rawValue,
            promptVersion: PromptVersion.specAuthor,
            locale: locale,
            model: .sparkLatest,
            effort: effort,
            maxOutputTokens: 6000,
            // Not streaming would run into the server-side time limit of the model host on a slow answer.
            stream: true,
            developerText: Prompts.specAuthor(locale: locale),
            userParts: [.inputText(text)] + images.map { .inputImage(dataURL: Self.dataURL(mediaType: "image/png", $0.png)) },
            format: StructuredFormat(name: "SpecDraft", schema: SpecDraft.schema),
            saw: WhatMuseSaw(
                feature: feature.rawValue, model: MuseModel.sparkLatest.rawValue, promptVersion: PromptVersion.specAuthor,
                effort: effort.rawValue, locale: locale.rawValue, input: json,
                images: images.map { SawImage(role: $0.source.role.rawValue, description: $0.source.summary, mediaType: "image/png", byteCount: $0.png.count) }
            ),
            inputHash: InsightHasher.hash(
                feature: feature, promptVersion: PromptVersion.specAuthor, model: .sparkLatest, effort: effort, locale: locale,
                subjectID: input.exerciseID.rawValue, input: json, images: images.map { .init(role: $0.source.role.rawValue, data: $0.png) }
            ),
            validate: { try $0.validated(for: input) },
            fallback: { SpecDraft.offline() }
        )
    }

    // MARK: Helpers

    private func events<Output: Codable & Sendable & Equatable>(
        _ work: @escaping @Sendable (@escaping @Sendable (InsightUpdate) -> Void) async throws -> InsightResult<Output>
    ) -> AsyncThrowingStream<InsightEvent<Output>, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let result = try await work { continuation.yield(.update($0)) }
                    continuation.yield(.finished(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func dataURL(mediaType: String, _ data: Data) -> String {
        "data:\(mediaType);base64,\(data.base64EncodedString())"
    }
}
