import Foundation
import Testing
@testable import MotionCore

/// A scripted clip whose true concentric velocities, and so its true velocity loss, follow from the script.
struct VelocityClip: Sendable, CustomTestStringConvertible {
    enum Shape: Sendable {
        /// Every rep at the same pace: the true loss is 0.
        case steady
        /// The reps slow down steadily through the set.
        case fading
        /// A steady first half, then a slowdown.
        case lateFade
    }

    var name: String
    var exercise: SyntheticMotion.Exercise
    var actions: [SyntheticMotion.Action]
    var shape: Shape = .steady
    var facing: SyntheticMotion.Facing = .right
    var glitches: SyntheticMotion.RandomGlitches?

    var testDescription: String { name }

    func motion(seed: UInt64) -> SyntheticMotion {
        SyntheticMotion(exercise: exercise, actions: actions, facing: facing, noise: .visionLike, randomGlitches: glitches, seed: seed)
    }

    /// The velocity the script performs on each rep the engine should count, in signal units per second:
    /// the distance travelled over the concentric time. A rep that stops far from the bottom is a partial.
    var truth: [Double] {
        let top = motion(seed: 0).topValue
        let prior = try! (exercise == .squat ? squatSpec() : pushUpSpec()).rep
        return actions.compactMap { action in
            guard case let .rep(rep) = action else { return nil }
            let depth = (rep.bottom - prior.bottomPrior) / (prior.topPrior - prior.bottomPrior)
            guard depth <= 0.3 else { return nil }
            return abs((rep.top ?? top) - rep.bottom) / rep.concentric
        }
    }

    /// The loss the script performs over the set: the last rep against the first.
    var truthLoss: Double {
        let velocities = truth
        return max(0, 1 - velocities[velocities.count - 1] / velocities[0])
    }
}

extension VelocityClip {
    private static func repeated(_ rep: SyntheticMotion.Rep, _ count: Int) -> [SyntheticMotion.Action] {
        Array(repeating: .rep(rep), count: count)
    }

    /// The synthetic benchmark of `motion-eval --synthetic`, plus fatigue on push-ups and a late fade.
    static let all: [VelocityClip] = {
        let dropouts = SyntheticMotion.RandomGlitches(
            joints: [.leftKnee, .rightKnee, .leftAnkle, .rightAnkle, .leftHip, .rightHip],
            ratePerSecond: 0.15, minDuration: 0.05, maxDuration: 0.12
        )
        return [
            VelocityClip(name: "squat 5", exercise: .squat, actions: repeated(.squat(), 5)),
            VelocityClip(name: "squat 10", exercise: .squat, actions: repeated(.squat(), 10)),
            VelocityClip(name: "squat 10 left", exercise: .squat, actions: repeated(.squat(), 10), facing: .left),
            VelocityClip(name: "squat 12 fast", exercise: .squat, actions: repeated(.squat(eccentric: 1.0, concentric: 0.8, pauseTop: 0.3), 12)),
            VelocityClip(name: "squat 8 pause", exercise: .squat, actions: repeated(.squat(pauseBottom: 1.2), 8)),
            VelocityClip(name: "squat 15 fatigue", exercise: .squat,
                         actions: (0..<15).map { .rep(.squat(eccentric: 1.4 + 0.03 * Double($0), concentric: 1.1 + 0.07 * Double($0))) },
                         shape: .fading),
            VelocityClip(name: "squat 8 and 2 partials", exercise: .squat,
                         actions: [.rep(.squat()), .rep(.squat()), .rep(.partialSquat()), .rep(.squat()), .rep(.squat()),
                                   .rep(.partialSquat()), .rep(.squat()), .rep(.squat()), .rep(.squat()), .rep(.squat())]),
            VelocityClip(name: "squat 10 dropouts", exercise: .squat, actions: repeated(.squat(), 10), glitches: dropouts),
            VelocityClip(name: "push-up 5", exercise: .pushUp, actions: repeated(.pushUp(), 5)),
            VelocityClip(name: "push-up 10", exercise: .pushUp, actions: repeated(.pushUp(), 10)),
            VelocityClip(name: "push-up 10 left", exercise: .pushUp, actions: repeated(.pushUp(), 10), facing: .left),
            VelocityClip(name: "push-up 12 fast", exercise: .pushUp, actions: repeated(.pushUp(eccentric: 0.9, concentric: 0.8, pauseTop: 0.3), 12)),
            VelocityClip(name: "push-up 8 pause", exercise: .pushUp, actions: repeated(.pushUp(pauseBottom: 1.0), 8)),
            VelocityClip(name: "push-up 8 and 2 partials", exercise: .pushUp,
                         actions: [.rep(.pushUp()), .rep(.pushUp()), .rep(.partialPushUp()), .rep(.pushUp()), .rep(.pushUp()),
                                   .rep(.partialPushUp()), .rep(.pushUp()), .rep(.pushUp()), .rep(.pushUp()), .rep(.pushUp())]),
            VelocityClip(name: "push-up 10 fatigue", exercise: .pushUp,
                         actions: (0..<10).map { .rep(.pushUp(eccentric: 1.2 + 0.04 * Double($0), concentric: 0.9 + 0.1 * Double($0))) },
                         shape: .fading),
            VelocityClip(name: "push-up 12 late fade", exercise: .pushUp,
                         actions: (0..<12).map { .rep(.pushUp(concentric: 1.1 * (1 + 0.16 * Double(max(0, $0 - 5))))) },
                         shape: .lateFade),
        ]
    }()

    static func named(_ prefix: String) -> [VelocityClip] { all.filter { $0.name.hasPrefix(prefix) } }
    static func with(_ shape: Shape, _ exercise: SyntheticMotion.Exercise) -> [VelocityClip] {
        all.filter { $0.shape == shape && $0.exercise == exercise }
    }
}

/// What the engine measured on one seeded run of a clip.
struct VelocityOutcome: Sendable {
    var clip: VelocityClip
    var seed: UInt64
    var repCount: Int
    var velocities: [Double]
    var loss: Double?
    var peak: Double?

    init(clip: VelocityClip, seed: UInt64) throws {
        let result = try run(clip.motion(seed: seed))
        self.clip = clip
        self.seed = seed
        repCount = result.reps.count
        velocities = result.reps.map(\.conVelocity)
        loss = result.summary.velocityLoss
        peak = result.summary.peakVelocityLoss
    }

    /// Each rep's measured velocity against the script, as a fraction of the truth.
    var repErrors: [Double] {
        let truth = clip.truth
        return velocities.count == truth.count ? zip(velocities, truth).map { ($0 - $1) / $1 } : []
    }

    /// The set's measured loss minus the scripted one.
    var lossError: Double { (loss ?? .nan) - clip.truthLoss }

    var label: String { "\(clip.name), seed \(seed)" }
}

/// Every clip on every seed, run once and shared by the tests below (in parallel: it is the slow part).
enum VelocitySweep {
    static let seeds: [UInt64] = Array(1...24)

    private final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [VelocityOutcome?]
        init(count: Int) { items = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ item: VelocityOutcome) { lock.withLock { items[index] = item } }
        var all: [VelocityOutcome] { lock.withLock { items.compactMap { $0 } } }
    }

    static let outcomes: [String: [VelocityOutcome]] = {
        let jobs = VelocityClip.all.flatMap { clip in seeds.map { (clip: clip, seed: $0) } }
        let slots = Slots(count: jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
            // The bundled specs always load; a failure here fails every test in the suite.
            slots.set(index, try! VelocityOutcome(clip: jobs[index].clip, seed: jobs[index].seed))
        }
        return Dictionary(grouping: slots.all, by: { $0.clip.name })
    }()

    static func outcomes(of clip: VelocityClip) -> [VelocityOutcome] { outcomes[clip.name] ?? [] }
    static func outcomes(of clips: [VelocityClip]) -> [VelocityOutcome] { clips.flatMap { outcomes(of: $0) } }
}

/// Tolerances, stated once. They come from the spread of the measurement itself: a rep's velocity is
/// read off a pose that wanders by about 3.4 % of the range for squats and 5.7 % for push-ups (whose
/// elbow angle comes from short arm segments), and that wander is correlated over about half a second, so
/// it cannot be averaged out inside a rep. Per-rep scatter is therefore about 7 % (squat) and 11 %
/// (push-up), and a 10-rep set of 11 % reps drifts by more than 10 % about one time in 25 by chance.
private enum Tolerance {
    /// A rep's velocity: bias of a clip's reps, their scatter, and the extremes a single rep may reach.
    static let repBias = 0.10
    static let repScatter = 0.15
    static let repWorst = -0.40...0.70

    /// A set without fatigue: no set reads above `steadyWorst`; at most `steadyAbove10` of them read above 0.10
    /// and `steadyAbove20` above 0.20; on average they read under `steadyMean`.
    static let steadyWorst = 0.30
    static let steadyAbove10 = 0.08
    static let steadyAbove20 = 0.03
    static let steadyMean = 0.03
    static let steadyPeak = 0.40

    /// A set with fatigue is reported a little low (the loss is held back by its own uncertainty), never
    /// much high: every set within `fadingLow` below and `fadingHigh` above the truth, the median set
    /// within `fadingMedian`, and at least `fadingWithin15` of the sets within 0.15.
    static let fadingLow = 0.30
    static let fadingHigh = 0.10
    static let fadingMedian = 0.08
    static let fadingWithin15 = 0.80
}

@Suite("Velocity loss against scripted truth")
struct VelocityLossTests {
    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    @Test("the truth follows the scripts")
    func truthFollowsScripts() throws {
        let squat10 = try #require(VelocityClip.named("squat 10").first)
        #expect(squat10.truth.count == 10 && squat10.truthLoss == 0)
        #expect(abs(squat10.truth[0] - 1.05 / 1.2) < 1e-9, "from -0.05 to 1.0 in 1.2 s")
        let pushUp = try #require(VelocityClip.named("push-up 10").first)
        #expect(abs(pushUp.truth[0] - 85 / 1.1) < 1e-9, "from 85 to 170 degrees in 1.1 s")
        #expect(try #require(VelocityClip.named("squat 8 and 2").first).truth.count == 8, "partials are not reps")
        #expect(try #require(VelocityClip.named("push-up 8 and 2").first).truth.count == 8)
        let fatigue = try #require(VelocityClip.named("squat 15 fatigue").first)
        #expect(abs(fatigue.truthLoss - 0.47) < 0.01, "1 - (1.1 / 2.08)")
        for clip in VelocityClip.all where clip.shape == .steady { #expect(clip.truthLoss == 0, "\(clip.name)") }
        for clip in VelocityClip.all where clip.shape != .steady { #expect(clip.truthLoss > 0.4, "\(clip.name)") }
    }

    @Test("rep counts stay exact on every seed", arguments: VelocityClip.all)
    func repCounts(clip: VelocityClip) {
        for outcome in VelocitySweep.outcomes(of: clip) {
            #expect(outcome.repCount == clip.truth.count, "\(outcome.label): counted \(outcome.repCount) of \(clip.truth.count)")
        }
    }

    @Test("a rep's measured velocity matches the script", arguments: VelocityClip.all)
    func repVelocity(clip: VelocityClip) {
        let errors = VelocitySweep.outcomes(of: clip).flatMap(\.repErrors)
        #expect(errors.count >= 5 * VelocitySweep.seeds.count)
        let mean = errors.reduce(0, +) / Double(errors.count)
        let scatter = (errors.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(errors.count)).squareRoot()
        #expect(abs(mean) < Tolerance.repBias, "mean error \(mean)")
        #expect(scatter < Tolerance.repScatter, "scatter \(scatter)")
        for outcome in VelocitySweep.outcomes(of: clip) {
            for (index, error) in outcome.repErrors.enumerated() {
                #expect(Tolerance.repWorst.contains(error), "\(outcome.label), rep \(index + 1): \(error)")
            }
        }
    }

    @Test("a set without fatigue reads about 0", arguments: [SyntheticMotion.Exercise.squat, .pushUp])
    func steadySets(exercise: SyntheticMotion.Exercise) throws {
        let outcomes = VelocitySweep.outcomes(of: VelocityClip.with(.steady, exercise))
        #expect(outcomes.count >= 5 * VelocitySweep.seeds.count)
        var losses: [Double] = []
        for outcome in outcomes {
            let loss = try #require(outcome.loss, "\(outcome.label)")
            losses.append(loss)
            #expect(loss >= 0 && loss <= Tolerance.steadyWorst, "\(outcome.label): loss \(loss)")
            let peak = try #require(outcome.peak, "\(outcome.label)")
            #expect(peak >= loss && peak <= Tolerance.steadyPeak, "\(outcome.label): peak \(peak)")
        }
        let share10 = Double(losses.filter { $0 > 0.10 }.count) / Double(losses.count)
        let share20 = Double(losses.filter { $0 > 0.20 }.count) / Double(losses.count)
        let mean = losses.reduce(0, +) / Double(losses.count)
        #expect(share10 <= Tolerance.steadyAbove10, "\(share10) of \(exercise) sets read above 10 %")
        #expect(share20 <= Tolerance.steadyAbove20, "\(share20) of \(exercise) sets read above 20 %")
        #expect(mean <= Tolerance.steadyMean, "mean loss \(mean)")
        for clip in VelocityClip.with(.steady, exercise) {
            let own = VelocitySweep.outcomes(of: clip).compactMap(\.loss)
            #expect(median(own) <= 0.02, "\(clip.name): the typical set reads \(median(own))")
        }
    }

    @Test("a set that fades is reported close to its scripted loss", arguments: [SyntheticMotion.Exercise.squat, .pushUp])
    func fadingSets(exercise: SyntheticMotion.Exercise) throws {
        for clip in VelocityClip.with(.fading, exercise) {
            let outcomes = VelocitySweep.outcomes(of: clip)
            var errors: [Double] = []
            for outcome in outcomes {
                let loss = try #require(outcome.loss, "\(outcome.label)")
                errors.append(loss - clip.truthLoss)
                #expect(
                    loss >= clip.truthLoss - Tolerance.fadingLow && loss <= clip.truthLoss + Tolerance.fadingHigh,
                    "\(outcome.label): loss \(loss) against \(clip.truthLoss)"
                )
                #expect(try #require(outcome.peak) >= loss, "\(outcome.label)")
            }
            #expect(abs(median(errors)) <= Tolerance.fadingMedian, "\(clip.name): median error \(median(errors))")
            let within = Double(errors.filter { abs($0) <= 0.15 }.count) / Double(errors.count)
            #expect(within >= Tolerance.fadingWithin15, "\(clip.name): \(within) of the sets within 0.15 of the truth")
        }
    }

    @Test("a fade late in the set is reported, though conservatively")
    func lateFade() throws {
        let clip = try #require(VelocityClip.with(.lateFade, .pushUp).first)
        let losses = try VelocitySweep.outcomes(of: clip).map { try #require($0.loss, "\($0.label)") }
        // The trend runs through the steady first half too, so it under-reads a hockey-stick fade (the true
        // loss is last rep against first). It must still show the fade, and never exceed the truth by much.
        #expect(median(losses) > 0.25 && median(losses) <= clip.truthLoss + 0.05,
                "typical \(median(losses)) against \(clip.truthLoss)")
        #expect(losses.filter { $0 > 0.10 }.count >= losses.count * 9 / 10, "the fade shows on nearly every set")
        #expect(losses.allSatisfy { $0 <= clip.truthLoss + Tolerance.fadingHigh })
    }
}
