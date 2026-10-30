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

    @Test("velocity loss compares each rep with the faster of the first two")
    func velocityLosses() {
        #expect(SetSummary.velocityLosses(velocities: []).isEmpty)
        #expect(SetSummary.velocityLosses(velocities: [1.0]) == [nil])
        let losses = SetSummary.velocityLosses(velocities: [1.0, 1.2, 1.2, 1.08, 0.9, 1.5])
        #expect(losses[0] == nil)
        let expected: [Double] = [0, 0, 0.1, 0.25, 0]   // reference is the faster of the first two: 1.2
        for (loss, want) in zip(losses.dropFirst(), expected) {
            #expect(abs((loss ?? -1) - want) < 1e-6, "\(String(describing: loss)) vs \(want)")
        }
        #expect(SetSummary.velocityLosses(velocities: [0, 0, 1]).allSatisfy { $0 == nil }, "no reference speed")
    }

    @Test("set-level numbers follow from the records")
    func summaryNumbers() {
        let reps = [
            record(index: 1, score: 100, velocity: 1.2),
            record(index: 2, score: 75, issues: [issue(.minor)], velocity: 1.2),
            record(index: 4, score: 50, issues: [issue(.major)], velocity: 0.9),
        ]
        let s = SetSummary(records: reps, partialRecords: [record(index: 3, counted: false)], isIdle: false, rejected: 1)
        #expect(s.reps == 3 && s.partials == 1 && s.goodReps == 2 && s.rejected == 1)
        #expect(s.averageScore == 75)
        #expect(abs((s.velocityLoss ?? -1) - 0.25) < 1e-9)
        #expect(abs((s.peakVelocityLoss ?? -1) - 0.25) < 1e-9)
        #expect(!s.isIdle)

        let none = SetSummary(records: [], partialRecords: [], isIdle: false, rejected: 0)
        #expect(none.averageScore == nil && none.velocityLoss == nil && none.peakVelocityLoss == nil)
        let one = SetSummary(records: [record()], partialRecords: [], isIdle: false, rejected: 0)
        #expect(one.velocityLoss == nil, "one rep has nothing to compare with")
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
