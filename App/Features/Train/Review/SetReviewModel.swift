import CoachKit
import Domain
import MotionCore
import Observation
import PoseCapture
import SwiftUI

/// What the review of one counted set is made from.
struct SetReviewSubject {
    let exercise: Exercise
    let spec: ExerciseSpec
    let logged: LoggedSet
    /// 1-based position of the set among the sets of this exercise in the workout.
    let setNumber: Int
    let localDay: LocalDay
    /// The frame at the bottom of each counted rep, by rep number. Only the live set has them.
    let bottomFrames: [Int: PoseFrame]
    let level: ActivityLevel
    let goal: GoalKind?
    let unitSystem: UnitSystem
    var trace: LiveTraceSnapshot? = nil
}

/// The review after a counted set. The on-device numbers are there from the start; Muse's words arrive after,
/// and only when the coach exists and the user opted in. Muse explains the numbers, it never changes them.
@MainActor
@Observable
final class SetReviewModel {
    enum Muse {
        /// No coach, or the user has not opted in: only the on-device review is shown.
        case off
        /// The coach exists but the user has not opted in: the consent card is shown.
        case needsConsent
        case streaming(SetReview.Partial, isRetrying: Bool)
        case finished(InsightResult<SetReview>)
        case failed(String)
    }

    let subject: SetReviewSubject
    /// Counted reps in order; `index` is the number on the chip.
    let reps: [RepEntry]
    private(set) var muse = Muse.off
    /// The pictures sent to Muse, kept for "What Muse saw".
    private(set) var sentImages: [SkeletonImage] = []
    var selectedRep: Int?
    let consent: AIConsent

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var museTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private let voice = CuePlayer()

    init(environment: AppEnvironment, subject: SetReviewSubject) {
        self.environment = environment
        self.subject = subject
        consent = AIConsent(environment: environment)
        reps = subject.logged.reps.sorted { $0.index < $1.index }
        // Open on the rep that needs the most attention, when there is one.
        if let weakest = reps.min(by: { $0.measurement.score < $1.measurement.score }), !weakest.measurement.issues.isEmpty {
            selectedRep = weakest.index
        }
    }

    var set: SetEntry { subject.logged.set }

    var isMuseRunning: Bool {
        if case .streaming = muse { true } else { false }
    }

    // MARK: Muse

    /// Starts the review once. Safe to call from every appearance of the screen.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        museTask = Task { await runMuse() }
    }

    /// Asks again after an offline answer or a failure.
    func retry() {
        museTask?.cancel()
        museTask = Task { await runMuse() }
    }

    /// Runs the review once the user opts in from the consent card.
    func consentGranted() {
        guard case .needsConsent = muse else { return }
        museTask?.cancel()
        museTask = Task {
            await TrainCoachAccess.awaitStoredConsent(in: environment)
            await runMuse()
        }
    }

    func cancel() {
        museTask?.cancel()
        voice.stop()
    }

    private func runMuse() async {
        guard let coach = await TrainCoachAccess.coach(in: environment) else {
            if await TrainCoachAccess.needsConsent(in: environment), !Task.isCancelled { muse = .needsConsent }
            return
        }
        muse = .streaming(SetReview.Partial(.null), isRetrying: false)
        let input = await makeInput()
        do {
            for try await event in coach.reviewSetEvents(input, locale: .app) {
                switch event {
                case .update(.partial(let json)):
                    muse = .streaming(SetReview.Partial(json), isRetrying: false)
                case .update(.retrying):
                    if case .streaming(let partial, _) = muse { muse = .streaming(partial, isRetrying: true) }
                case .finished(let result):
                    muse = .finished(result)
                    if result.origin == .muse { await speak(result.output.headline) }
                }
            }
        } catch is CancellationError {
            return
        } catch {
            // CoachKit's error texts are English and technical; the review itself is on screen either way.
            muse = .failed(String(localized: "Muse could not answer."))
        }
    }

    private func speak(_ headline: String) async {
        let wanted = (try? await environment.settings.get(SettingKey.voiceCues)) ?? true
        if wanted, !Task.isCancelled { voice.speak(headline) }
    }

    private func makeInput() async -> SetReviewInput {
        let history = (try? await environment.workouts.recentSets(exerciseID: subject.exercise.id, limit: 6)) ?? []
        let previous = history.first { $0.set.tracking == .camera } ?? history.first
        let images = await Self.skeletons(reps: reps, frames: subject.bottomFrames, spec: subject.spec)
        sentImages = images
        return SetReviewInput(
            set: set,
            reps: reps,
            exerciseID: subject.exercise.id,
            exerciseName: subject.exercise.name,
            specVersion: subject.spec.version,
            localDay: subject.localDay,
            level: subject.level,
            goal: subject.goal,
            unitSystem: subject.unitSystem,
            lastComparable: previous.map(PriorSet.init),
            images: images
        )
    }

    /// The best and the worst rep at the bottom, drawn as skeletons. One picture when they are the same rep.
    @concurrent
    private static func skeletons(reps: [RepEntry], frames: [Int: PoseFrame], spec: ExerciseSpec) async -> [SkeletonImage] {
        let drawable = reps.filter { frames[$0.index] != nil }
        guard let best = drawable.max(by: { ($0.measurement.score, -$0.index) < ($1.measurement.score, -$1.index) }) else { return [] }
        var chosen = [(SkeletonImage.Role.bestRepBottom, best)]
        if let worst = drawable.min(by: { ($0.measurement.score, $0.index) < ($1.measurement.score, $1.index) }),
           worst.index != best.index, worst.measurement.score < best.measurement.score {
            chosen.append((.worstRepBottom, worst))
        }
        let renderer = SkeletonRenderer(spec: spec)
        return chosen.compactMap { role, rep in
            guard let frame = frames[rep.index],
                  let png = try? renderer.pngData(for: frame, repLabel: "rep \(rep.index)") else { return nil }
            return SkeletonImage(role: role, rep: rep.index, png: png)
        }
    }
}
