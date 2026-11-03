import CoachKit
import Domain
import Foundation
import MotionCore
import Observation
import PoseCapture

/// Form checks for a taught exercise (teach-mode slice B). After the demonstration counts, Muse is shown two stick
/// figures and numbers measured on the phone and proposes up to three checks from a fixed menu. The phone eases
/// each threshold to the demonstration, replays the demonstration with the checks, and keeps only what still
/// counts every rep and finds no fault in the user's own demonstration (Gate 2).
///
/// Nothing here runs unless the user allowed Muse (`aiOptIn` is read right before the request), and any failure
/// leaves the exercise exactly as slice A saves it: counted, without form checks.
@MainActor
@Observable
final class TeachFormChecks {
    enum State: Equatable {
        /// Muse is not used: no consent, no coach, or not started. Nothing is shown.
        case off
        case thinking
        /// At least one check passed Gate 2.
        case ready
        /// Muse answered with nothing usable, could not be reached, or no check survived.
        case plain
    }

    struct Item: Identifiable, Equatable {
        var id: TaughtRuleTemplate { template }
        let template: TaughtRuleTemplate
        let why: String
        let threshold: Double
        let proposed: Double
        let wasRelaxed: Bool
    }

    /// The longest the user waits for Muse.
    static let deadlineSeconds = 25.0

    private(set) var state = State.off
    private(set) var items: [Item] = []
    /// How many checks Muse proposed.
    private(set) var proposedCount = 0
    /// What Muse was sent, for "What Muse saw".
    private(set) var saw: WhatMuseSaw?
    private(set) var sentImages: [SkeletonImage] = []
    /// What Muse thinks the exercise works, applied by the model only when the user has chosen nothing.
    private(set) var suggestion: (muscles: [MuscleGroup], equipment: Equipment)?
    /// The user may turn the checks off before saving.
    var isEnabled = true

    /// The spec with the surviving checks, or nil when the exercise saves as slice A has it.
    var acceptedSpec: ExerciseSpec? { state == .ready && isEnabled ? built : nil }

    @ObservationIgnored private var built: ExerciseSpec?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Forgets everything and stops any request.
    func reset() {
        task?.cancel()
        task = nil
        state = .off
        items = []
        proposedCount = 0
        saw = nil
        sentImages = []
        suggestion = nil
        built = nil
        isEnabled = true
    }

    /// Starts once the demonstration has counted. `onSuggestion` runs on the main actor when Muse's guess about the
    /// exercise arrives.
    func begin(
        exerciseID: ExerciseID, name: String, baseline: ExerciseSpec, result: TeachResult, reps: Int,
        onSuggestion: @escaping (_ muscles: [MuscleGroup], _ equipment: Equipment) -> Void
    ) {
        reset()
        task = Task { await run(exerciseID: exerciseID, name: name, baseline: baseline, result: result, reps: reps, onSuggestion: onSuggestion) }
    }

    private func run(
        exerciseID: ExerciseID, name: String, baseline: ExerciseSpec, result: TeachResult, reps: Int,
        onSuggestion: (_ muscles: [MuscleGroup], _ equipment: Equipment) -> Void
    ) async {
        // The consent check comes first and again right before the request.
        guard await TrainCoachAccess.coach(in: environment) != nil else { return }
        state = .thinking
        guard let prepared = await Self.prepare(exerciseID: exerciseID, name: name, baseline: baseline, result: result, reps: reps),
              !Task.isCancelled else {
            finishPlain()
            return
        }
        sentImages = prepared.input.images
        guard let coach = await TrainCoachAccess.coach(in: environment), !Task.isCancelled else {
            state = .off
            return
        }
        let answer: InsightResult<SpecDraft>
        do {
            answer = try await Self.ask(coach, prepared.input, seconds: Self.deadlineSeconds)
        } catch {
            // Offline, over the deadline or refused: the exercise is kept as taught.
            if !Task.isCancelled { finishPlain() }
            return
        }
        guard !Task.isCancelled else { return }
        guard answer.origin == .muse else {
            finishPlain()
            return
        }
        saw = answer.whatMuseSaw
        proposedCount = answer.output.checks.count
        if !answer.output.primaryMuscles.isEmpty {
            suggestion = (answer.output.primaryMuscles, answer.output.equipment)
            onSuggestion(answer.output.primaryMuscles, answer.output.equipment)
        }
        let proposal = TaughtProposal(
            checks: answer.output.checks.map {
                .init(template: $0.template, threshold: $0.threshold, severity: Severity(rawValue: $0.severity.rawValue) ?? .minor, weight: $0.weight)
            }
        )
        let build = await Self.build(prepared.analysis, proposal: proposal)
        guard !Task.isCancelled else { return }
        guard let spec = build.spec, !build.kept.isEmpty else {
            finishPlain()
            return
        }
        let reasons = Dictionary(answer.output.checks.map { ($0.template, $0.why) }, uniquingKeysWith: { first, _ in first })
        items = build.kept.map {
            Item(
                template: $0.template, why: reasons[$0.template.rawValue] ?? "", threshold: $0.threshold,
                proposed: $0.proposedThreshold, wasRelaxed: $0.wasRelaxed
            )
        }
        built = spec
        state = .ready
    }

    private func finishPlain() {
        items = []
        built = nil
        state = .plain
    }

    // MARK: Off the main actor

    nonisolated struct Prepared: Sendable {
        var analysis: TaughtAnalysis
        var input: SpecAuthorInput
    }

    /// Finds what the demonstration measured and draws the two poses. Nil when nothing can be measured.
    @concurrent
    private static func prepare(exerciseID: ExerciseID, name: String, baseline: ExerciseSpec, result: TeachResult, reps: Int) async -> Prepared? {
        guard let analysis = try? TaughtSpecBuilder.analyze(baseline: baseline, take: result.take(confirming: reps)),
              !analysis.menu.isEmpty else { return nil }
        let summary = DemoSummary(result: result, reps: analysis.reps, confirmedReps: reps)
        guard let data = try? JSONEncoder().encode(summary), let json = try? JSONValue(jsonData: data) else { return nil }
        // Stick figures only: Muse never gets a camera frame.
        let renderer = SkeletonRenderer(options: .init(showGuides: false))
        guard let start = try? renderer.pngData(for: result.topFrame),
              let middle = try? renderer.pngData(for: result.bottomFrame) else { return nil }
        let menu = analysis.menu.map {
            SpecAuthorMenuEntry(
                template: $0.template.rawValue, meaning: $0.template.meaning, unit: $0.template.unit,
                min: $0.range.lowerBound, max: $0.range.upperBound,
                observedMin: $0.observedMin, observedMedian: $0.observedMedian, observedMax: $0.observedMax
            )
        }
        let input = SpecAuthorInput(
            exerciseID: exerciseID, exerciseName: name, demoSummary: json, menu: menu,
            images: [SkeletonImage(role: .taughtStart, png: start), SkeletonImage(role: .taughtMiddle, png: middle)]
        )
        return Prepared(analysis: analysis, input: input)
    }

    @concurrent
    private static func build(_ analysis: TaughtAnalysis, proposal: TaughtProposal) async -> TaughtBuild {
        TaughtSpecBuilder.build(analysis, proposal: proposal)
    }

    /// The request, given up on after `seconds`.
    @concurrent
    private static func ask(_ coach: CoachService, _ input: SpecAuthorInput, seconds: Double) async throws -> InsightResult<SpecDraft> {
        try await withThrowingTaskGroup(of: InsightResult<SpecDraft>?.self) { group in
            group.addTask { try await coach.authorSpec(input, locale: .app) }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let answer = first else { throw CoachError.network("Muse took too long.") }
            return answer
        }
    }

    // MARK: Words

    /// The threshold as a person reads it.
    static func text(_ template: TaughtRuleTemplate, _ value: Double) -> String {
        switch template {
        case .reachBottom, .returnTop:
            return value.formatted(.percent.precision(.fractionLength(0)))
        case .slowDown, .controlUp:
            return Measurement(value: value / 1000, unit: UnitDuration.seconds)
                .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0...2))))
        case .chestUp, .bodyStraight, .lockOut:
            return "\(Int(value.rounded()))°"
        }
    }
}
