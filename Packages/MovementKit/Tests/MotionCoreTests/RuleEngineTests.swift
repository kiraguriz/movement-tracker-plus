import Foundation
import Testing
@testable import MotionCore

@Suite("Rule engine")
struct RuleEngineTests {
    private func engine() throws -> RuleEngine { RuleEngine(spec: try squatSpec()) }

    private let clean: [MetricKey: Double] = [.bottomValue: -0.05, .maxTorsoLeanDegDescent: 35, .eccMs: 1200]

    @Test("a clean rep scores 100 with no issues and is good")
    func cleanRep() throws {
        let result = try engine().evaluate(clean)
        #expect(result.issues.isEmpty && result.score == 100 && result.isGood)
    }

    @Test("a violated rule costs 100 times its weight")
    func penalties() throws {
        var m = clean
        m[.bottomValue] = 0.4
        var result = try engine().evaluate(m)
        #expect(result.score == 50 && result.issues.map(\.ruleID) == ["depth"])
        #expect(!result.isGood, "a major issue is never good")

        m = clean
        m[.maxTorsoLeanDegDescent] = 60
        result = try engine().evaluate(m)
        #expect(result.score == 75 && result.isGood, "one minor issue at 75 is still good")

        m = clean
        m[.maxTorsoLeanDegDescent] = 60
        m[.eccMs] = 400
        result = try engine().evaluate(m)
        #expect(result.score == 50 && !result.isGood, "two minors drop below 70")
    }

    @Test("the score is clamped to 0...100")
    func clamping() throws {
        var spec = try squatSpec()
        spec.score = ["depth": 0.6, "chest": 0.3, "tempo": 0.1]
        spec.rules[0].value = -10
        spec.rules[1].value = -10
        spec.rules[2].value = 1e9
        let result = RuleEngine(spec: spec).evaluate(clean)
        #expect(result.issues.count == 3 && result.score == 0 && !result.isGood)
    }

    @Test("good means score of at least 70 and no major issue: the boundary")
    func goodBoundary() throws {
        var spec = try squatSpec()
        // One minor rule worth exactly 30: score 70 is good, 69 is not.
        spec.score = ["depth": 0.0, "chest": 0.30, "tempo": 0.0]
        var m = clean
        m[.maxTorsoLeanDegDescent] = 90
        #expect(RuleEngine(spec: spec).evaluate(m).score == 70)
        #expect(RuleEngine(spec: spec).evaluate(m).isGood)
        spec.score["chest"] = 0.31
        #expect(RuleEngine(spec: spec).evaluate(m).score == 69)
        #expect(!RuleEngine(spec: spec).evaluate(m).isGood)
        // A major issue with a weight of zero still blocks "good".
        spec.score = [:]
        m[.bottomValue] = 0.9
        let result = RuleEngine(spec: spec).evaluate(m)
        #expect(result.score == 100 && !result.isGood)
        #expect(RuleEngine.goodScoreThreshold == 70)
    }

    @Test("an unmeasured metric is skipped, not punished")
    func missingMetric() throws {
        let result = try engine().evaluate([.bottomValue: -0.05])
        #expect(result.issues.isEmpty && result.score == 100)
        let nan = try engine().evaluate([.bottomValue: .nan, .eccMs: .infinity])
        #expect(nan.issues.isEmpty)
    }

    @Test("limits are inclusive for <= and >=, exclusive for < and >")
    func operators() {
        #expect(RuleOperator.lessOrEqual.holds(1, 1) && !RuleOperator.lessOrEqual.holds(1.0001, 1))
        #expect(RuleOperator.greaterOrEqual.holds(1, 1) && !RuleOperator.greaterOrEqual.holds(0.9999, 1))
        #expect(!RuleOperator.less.holds(1, 1) && RuleOperator.less.holds(0.9999, 1))
        #expect(!RuleOperator.greater.holds(1, 1) && RuleOperator.greater.holds(1.0001, 1))
    }

    @Test("an issue carries the measured value, the limit, and the cue")
    func issueDetails() throws {
        let result = try engine().evaluate([.bottomValue: 0.3])
        let issue = try #require(result.issues.first)
        #expect(issue.metric == .bottomValue && issue.value == 0.3 && issue.limit == 0.10)
        #expect(issue.severity == .major && issue.cue == "cue.squat.deeper")
    }

    @Test("push-up rules")
    func pushUpRules() throws {
        let rules = RuleEngine(spec: try pushUpSpec())
        let clean: [MetricKey: Double] = [.bottomValue: 88, .minBodyLineDeg: 172, .topElbowDeg: 165]
        #expect(rules.evaluate(clean).isGood)
        var sag = clean
        sag[.minBodyLineDeg] = 150
        let sagged = rules.evaluate(sag)
        #expect(sagged.issues.map(\.cue) == ["cue.pushup.hipsLevel"] && !sagged.isGood)
        var shallow = clean
        shallow[.bottomValue] = 120
        #expect(rules.evaluate(shallow).issues.map(\.cue) == ["cue.pushup.lower"])
        var soft = clean
        soft[.topElbowDeg] = 140
        let lockout = rules.evaluate(soft)
        #expect(lockout.issues.map(\.cue) == ["cue.pushup.lockOut"] && lockout.score == 75 && lockout.isGood)
    }
}

@Suite("Cue scheduler")
struct CueSchedulerTests {
    private func issue(_ id: String, _ severity: Severity, cue: String? = nil) -> MotionCore.Issue {
        MotionCore.Issue(ruleID: id, metric: .bottomValue, severity: severity, cue: CueKey(cue ?? "cue.\(id)"), value: 0, limit: 0)
    }

    @Test("no issues, no cue")
    func none() {
        var scheduler = CueScheduler()
        #expect(scheduler.cue(for: [], at: 10) == nil)
    }

    @Test("the major issue is chosen over a minor one regardless of order")
    func severityFirst() {
        var scheduler = CueScheduler()
        #expect(scheduler.cue(for: [issue("a", .minor), issue("b", .major)], at: 10) == "cue.b")
    }

    @Test("equal severity keeps the spec order")
    func specOrder() {
        var scheduler = CueScheduler()
        #expect(scheduler.cue(for: [issue("a", .minor), issue("b", .minor)], at: 10) == "cue.a")
    }

    @Test("nothing within the rate limit of the previous cue; free right after it")
    func rateLimit() {
        var scheduler = CueScheduler(minIntervalSeconds: 3)
        #expect(scheduler.cue(for: [issue("a", .major)], at: 10) == "cue.a")
        #expect(scheduler.cue(for: [issue("a", .major)], at: 11.5) == nil)
        #expect(scheduler.cue(for: [issue("b", .major)], at: 12.99) == nil)
        #expect(scheduler.cue(for: [issue("a", .major)], at: 13) == "cue.a")
    }

    @Test("a suppressed cue does not reset the clock")
    func suppressedDoesNotExtend() {
        var scheduler = CueScheduler(minIntervalSeconds: 3)
        _ = scheduler.cue(for: [issue("a", .major)], at: 10)
        _ = scheduler.cue(for: [issue("a", .major)], at: 12)
        #expect(scheduler.cue(for: [issue("a", .major)], at: 13.1) != nil)
    }

    @Test("the same minor cue is not repeated back to back, but a major one is allowed to repeat")
    func minorRepeat() {
        var scheduler = CueScheduler(minIntervalSeconds: 3)
        #expect(scheduler.cue(for: [issue("tempo", .minor)], at: 10) == "cue.tempo")
        #expect(scheduler.cue(for: [issue("tempo", .minor)], at: 20) == nil)
        #expect(scheduler.cue(for: [issue("chest", .minor)], at: 30) == "cue.chest")
        #expect(scheduler.cue(for: [issue("tempo", .minor)], at: 40) == "cue.tempo")

        var major = CueScheduler(minIntervalSeconds: 3)
        #expect(major.cue(for: [issue("depth", .major)], at: 10) == "cue.depth")
        #expect(major.cue(for: [issue("depth", .major)], at: 20) == "cue.depth")
    }

    @Test("a repeated minor falls through to another issue on the same rep")
    func fallThrough() {
        var scheduler = CueScheduler(minIntervalSeconds: 3)
        _ = scheduler.cue(for: [issue("tempo", .minor)], at: 10)
        #expect(scheduler.cue(for: [issue("tempo", .minor), issue("chest", .minor)], at: 20) == "cue.chest")
    }

    @Test("pipeline: a faulty set gets cues no closer than three seconds, and only valid keys")
    func pipelineRateLimit() throws {
        let motion = SyntheticMotion.squats(reps: 8, rep: .squat(bottom: 0.25, eccentric: 1.2, concentric: 1.0, pauseTop: 0.2))
        let result = try run(motion)
        #expect(result.reps.count == 8)
        #expect(result.reps.allSatisfy { !$0.isGood }, "every rep stops above the depth limit")
        let times: [Double] = {
            var out: [Double] = []
            var repIndex = 0
            for event in result.events {
                switch event {
                case let .repCompleted(r): repIndex += 1; _ = r
                case .cue: out.append(result.reps[repIndex - 1].tEnd)
                default: break
                }
            }
            return out
        }()
        #expect(!times.isEmpty && result.cues.count == times.count)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 - $0 >= 3 - 1e-9 })
        #expect(result.cues.allSatisfy { $0 == "cue.squat.deeper" })
        #expect(result.cues.count < 8, "rate limiting held some back")
    }
}
