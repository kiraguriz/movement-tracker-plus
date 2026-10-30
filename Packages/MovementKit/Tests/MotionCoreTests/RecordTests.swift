import Foundation
import Testing
@testable import MotionCore

@Suite("Records and events")
struct RecordTests {
    private func record(
        index: Int = 1, counted: Bool = true, score: Int = 100, issues: [MotionCore.Issue] = [], velocity: Double = 1.2
    ) -> RepRecord {
        RepRecord(
            index: index, isCounted: counted, tStart: 10, tBottom: 10.7, tLift: 11.0, tEnd: 11.7,
            eccMs: 700, conMs: 700, rom: 0.95, bottomValue: 0.02, topValue: 0.99, conVelocity: velocity,
            metrics: [.bottomValue: 0.02, .maxTorsoLeanDegDescent: 38.5, .eccMs: 700],
            issues: issues, score: score
        )
    }

    private func issue(_ severity: Severity) -> MotionCore.Issue {
        MotionCore.Issue(ruleID: "depth", metric: .bottomValue, severity: severity, cue: "cue.squat.deeper", value: 0.3, limit: 0.1)
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test("a rep record survives JSON, including its metric dictionary")
    func repRecordCoding() throws {
        let r = record(score: 75, issues: [issue(.minor)])
        #expect(try roundTrip(r) == r)
    }

    @Test("a rep is good only when its score is at least 70 and it has no major issue")
    func isGood() {
        #expect(record(score: 100).isGood)
        #expect(record(score: 70).isGood)
        #expect(!record(score: 69).isGood)
        #expect(!record(score: 100, issues: [issue(.major)]).isGood)
        #expect(record(score: 80, issues: [issue(.minor)]).isGood)
        #expect(!record(counted: false, score: 100).isGood, "a partial is never good")
    }

    @Test("every event kind survives JSON")
    func eventCoding() throws {
        let events: [MotionEvent] = [
            .framing(.ready), .framing(.turnSideways), .phase(.descending), .repCompleted(record()),
            .partialRep(record(counted: false, score: 0)), .cue("cue.squat.deeper"), .signal(0.42), .idle,
        ]
        for event in events { #expect(try roundTrip(event) == event) }
        #expect(try roundTrip(events) == events)
    }

    @Test("a set summary survives JSON")
    func summaryCoding() throws {
        let summary = SetSummary(
            records: [record(index: 1), record(index: 2, velocity: 1.0)], partialRecords: [record(index: 3, counted: false)],
            isIdle: true, rejected: 2
        )
        #expect(try roundTrip(summary) == summary)
    }

    @Test("the engine's configuration survives JSON and has the documented defaults")
    func configCoding() throws {
        let config = MotionConfig.default
        #expect(try roundTrip(config) == config)
        #expect(config.confidenceThreshold == 0.3 && config.maxGapSeconds == 0.15)
        #expect(config.filter.minCutoff == 2 && config.filter.beta == 6 && config.filter.dCutoff == 1.5)
        #expect(config.view.sideBelow == 0.3 && config.view.frontAbove == 0.5)
        #expect(config.sideLock.switchSeconds == 1 && config.sideLock.margin == 0.15)
        #expect(config.framing.holdSeconds == 1 && config.framing.lossSeconds == 0.5)
        #expect(config.segmenter.topEnter == 0.7 && config.segmenter.bottomEnter == 0.3)
        #expect(config.segmenter.topLeave == 0.6 && config.segmenter.bottomLeave == 0.4)
        #expect(config.cues.minIntervalSeconds == 3)
    }

    @Test("enums keep stable raw values for stored data")
    func rawValues() {
        #expect(Phase.allCases.map(\.rawValue) == ["top", "descending", "bottom", "ascending"])
        #expect(FramingState.allCases.map(\.rawValue) == [
            "noPerson", "stepBack", "moveCloser", "wholeBody", "turnSideways", "faceCamera", "holdStill", "ready",
        ])
        #expect(Severity.minor < Severity.major && !(Severity.major < Severity.minor))
        #expect(MetricKey.maxTorsoLeanDegDescent.rawValue == "maxTorsoLeanDeg@descent")
    }

    /// The set's true loss for a velocity that falls by a constant factor per rep.
    private func geometric(_ ratio: Double, reps: Int) -> (velocities: [Double], truth: Double) {
        ((0..<reps).map { pow(ratio, Double($0)) }, 1 - pow(ratio, Double(reps - 1)))
    }

    @Test("velocity loss needs four reps")
    func velocityLossNeedsFourReps() {
        #expect(SetSummary.velocityLosses(velocities: []).isEmpty)
        #expect(SetSummary.velocityLosses(velocities: [1.0]) == [nil])
        let losses = SetSummary.velocityLosses(velocities: [1.0, 0.9, 0.8, 0.7, 0.6])
        #expect(losses.count == 5)
        #expect(losses[0..<3].allSatisfy { $0 == nil }, "three reps cannot tell a trend from noise")
        #expect(losses[3] != nil && losses[4] != nil)
        #expect(SetSummary.minimumRepsForVelocityLoss == 4)
    }

    @Test("a steady set reads 0, and so does one that speeds up")
    func velocityLossSteadyOrFaster() {
        let steady = SetSummary.velocityLosses(velocities: Array(repeating: 1.2, count: 8))
        #expect(steady.dropFirst(3).allSatisfy { abs($0 ?? -1) < 1e-12 })
        let faster = SetSummary.velocityLosses(velocities: [1.0, 1.05, 1.1, 1.2, 1.25, 1.3])
        #expect(faster.dropFirst(3).allSatisfy { abs($0 ?? -1) < 1e-12 }, "no negative loss: \(faster)")
    }

    @Test("a steady decline is reported close to the truth and never above it")
    func velocityLossFollowsADecline() throws {
        for (ratio, reps) in [(0.97, 10), (0.93, 10), (0.88, 12), (0.9, 8)] {
            let (velocities, truth) = geometric(ratio, reps: reps)
            let loss = try #require(SetSummary.velocityLosses(velocities: velocities).last ?? nil)
            #expect(loss <= truth + 1e-9 && loss > truth - 0.07, "ratio \(ratio): \(loss) against \(truth)")
        }
    }

    @Test("one bad rep cannot swing the loss, wherever it falls")
    func velocityLossIgnoresOneBadRep() throws {
        for bad in 0..<10 {
            var velocities = Array(repeating: 1.0, count: 10)
            velocities[bad] = 0.4
            let loss = try #require(SetSummary.velocityLosses(velocities: velocities).last ?? nil)
            #expect(loss < 0.02, "rep \(bad) at 0.4: \(loss)")
        }
        // The same slow last rep read 60 % under the old rule (the last rep against the faster of the first two).
        var tired = Array(repeating: 1.0, count: 9)
        tired += [0.4]
        #expect(try #require(SetSummary.velocityLosses(velocities: tired).last ?? nil) < 0.02)
    }

    @Test("scatter around a flat velocity is not fatigue")
    func velocityLossIgnoresScatter() throws {
        let velocities = [1.12, 1.0, 1.1, 0.92, 1.05, 1.08, 0.95, 1.1, 1.0, 0.88]
        // The old rule read 1 − 0.88 / 1.12 = 21 % here.
        let loss = try #require(SetSummary.velocityLosses(velocities: velocities).last ?? nil)
        #expect(loss < 0.05, "loss \(loss)")
    }

    @Test("a set that holds its pace and then slows down shows the slowing")
    func velocityLossLateFatigue() throws {
        let velocities = [1, 1.02, 0.99, 1.01, 1, 0.97, 0.9, 0.82, 0.74, 0.66, 0.6, 0.55]
        let loss = try #require(SetSummary.velocityLosses(velocities: velocities).last ?? nil)
        #expect(loss > 0.25, "the last reps are 45 % slower; the trend is conservative: \(loss)")
        #expect(loss < 0.5)
    }

    @Test("reps without a usable velocity are skipped and keep their place in the trend")
    func velocityLossSkipsBadVelocities() throws {
        #expect(SetSummary.velocityLosses(velocities: [0, 0, 1]).allSatisfy { $0 == nil }, "no speed to compare")
        #expect(SetSummary.velocityLosses(velocities: [1, .nan, 1, 1, 1, .infinity, 1, 1]).last! == 0)
        let (velocities, truth) = geometric(0.9, reps: 10)
        var holey = velocities
        holey[3] = 0
        holey[6] = .nan
        let loss = try #require(SetSummary.velocityLosses(velocities: holey).last ?? nil)
        #expect(loss <= truth + 1e-9 && loss > truth - 0.07, "\(loss) against \(truth)")
    }

    @Test("the live value after each rep never depends on later reps")
    func velocityLossesArePrefixes() {
        let velocities = [1.0, 1.1, 0.95, 1.0, 0.9, 0.85, 0.8, 0.82, 0.7]
        let live = SetSummary.velocityLosses(velocities: velocities)
        for index in velocities.indices {
            #expect(live[index] == SetSummary.velocityLosses(velocities: Array(velocities[...index])).last!)
        }
    }

    @Test("set-level numbers follow from the records")
    func summaryNumbers() throws {
        let velocities = [1.2, 1.2, 1.1, 1.0, 0.9, 0.8]
        let reps = [
            record(index: 1, score: 100, velocity: velocities[0]),
            record(index: 2, score: 75, issues: [issue(.minor)], velocity: velocities[1]),
            record(index: 4, score: 50, issues: [issue(.major)], velocity: velocities[2]),
            record(index: 5, score: 75, velocity: velocities[3]),
            record(index: 6, score: 100, velocity: velocities[4]),
            record(index: 7, score: 100, velocity: velocities[5]),
        ]
        let s = SetSummary(records: reps, partialRecords: [record(index: 3, counted: false)], isIdle: false, rejected: 1)
        #expect(s.reps == 6 && s.partials == 1 && s.goodReps == 5 && s.rejected == 1)
        #expect(abs((s.averageScore ?? -1) - 500.0 / 6) < 1e-9)
        let live = SetSummary.velocityLosses(velocities: velocities)
        #expect(s.velocityLoss == live.last!)
        #expect(s.peakVelocityLoss == live.compactMap { $0 }.max())
        #expect(try #require(s.velocityLoss) > 0.1, "a clear slowdown")
        #expect(!s.isIdle)

        let none = SetSummary(records: [], partialRecords: [], isIdle: false, rejected: 0)
        #expect(none.averageScore == nil && none.velocityLoss == nil && none.peakVelocityLoss == nil)
        let one = SetSummary(records: [record()], partialRecords: [], isIdle: false, rejected: 0)
        #expect(one.velocityLoss == nil, "one rep has nothing to compare with")
        let three = SetSummary(records: (1...3).map { record(index: $0) }, partialRecords: [], isIdle: false, rejected: 0)
        #expect(three.velocityLoss == nil && three.peakVelocityLoss == nil, "three reps are too few")
    }

    @Test("velocity loss on a fatiguing set grows as the bar slows")
    func fatiguingSet() throws {
        // Each rep's concentric takes 6 % longer than the last.
        var actions: [SyntheticMotion.Action] = []
        for i in 0..<8 { actions.append(.rep(.squat(eccentric: 1.4, concentric: 1.0 * pow(1.12, Double(i)), pauseTop: 0.6))) }
        let result = try run(SyntheticMotion(exercise: .squat, actions: actions, noise: .visionLike, seed: 8))
        #expect(result.reps.count == 8)
        let velocities = result.reps.map(\.conVelocity)
        #expect(zip(velocities, velocities.dropFirst()).filter { $1 < $0 }.count >= 5, "mostly slowing: \(velocities)")
        let loss = try #require(result.summary.velocityLoss)
        // 1.12^7 = 2.2 times slower: the true loss is about 55 %.
        #expect(loss > 0.35 && loss < 0.7, "loss \(loss)")
        #expect(try #require(result.summary.peakVelocityLoss) >= loss - 1e-9)
    }

    @Test("a constant-speed set shows almost no velocity loss")
    func steadySet() throws {
        let result = try run(SyntheticMotion(exercise: .squat, actions: Array(repeating: .rep(.squat()), count: 8), noise: .visionLike, seed: 2))
        #expect(result.reps.count == 8)
        let loss = try #require(result.summary.velocityLoss)
        #expect(loss < 0.15, "loss \(loss)")
    }
}
