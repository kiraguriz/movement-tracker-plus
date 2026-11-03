import Foundation
import Testing
@testable import MotionCore

@Suite("Exercise spec")
struct ExerciseSpecTests {
    // MARK: Bundled specs

    @Test("the squat spec has the documented values")
    func squatValues() throws {
        let spec = try squatSpec()
        #expect(spec.id == "squat.bodyweight" && spec.version == 1 && spec.view == .side)
        #expect(spec.requiredJoints == [.shoulder, .hip, .knee, .ankle])
        #expect(spec.signal == .relativeHeight(of: .hip, to: .knee, scale: .thigh))
        #expect(spec.rep.polarity == .down)
        #expect(spec.rep.topPrior == 1.0 && spec.rep.bottomPrior == 0.05 && spec.rep.minRom == 0.45)
        #expect(spec.rep.dwellMs == 70 && spec.rep.minPeriodMs == 400 && spec.rep.maxPeriodMs == 12_000)
        #expect(spec.rep.idleSeconds == 20)
        #expect(spec.rules.map(\.id) == ["depth", "chest", "tempo"])
        #expect(spec.rules.first { $0.id == "depth" }?.severity == .major)
        #expect(abs(spec.score.values.reduce(0, +) - 1) < 1e-9)
    }

    @Test("the push-up spec has the documented values")
    func pushUpValues() throws {
        let spec = try pushUpSpec()
        #expect(spec.id == "pushup" && spec.view == .side)
        #expect(spec.requiredJoints == [.shoulder, .elbow, .wrist, .hip, .ankle])
        #expect(spec.signal == .jointAngle(a: .shoulder, b: .elbow, c: .wrist))
        #expect(spec.rep.topPrior == 165 && spec.rep.bottomPrior == 85 && spec.rep.minRom == 45)
        #expect(spec.rules.map(\.id) == ["depth", "bodyLine", "lockout"])
        #expect(spec.rules.filter { $0.severity == .major }.map(\.id) == ["depth", "bodyLine"])
        #expect(abs(spec.score.values.reduce(0, +) - 1) < 1e-9)
    }

    @Test("the jumping jack spec has the documented values")
    func jumpingJackValues() throws {
        let spec = try jumpingJackSpec()
        #expect(spec.id == "jumpingjack" && spec.version == 1 && spec.view == .front)
        #expect(spec.requiredJoints == [.hip, .shoulder, .elbow, .ankle])
        #expect(spec.signal == .jointAngle(a: .hip, b: .shoulder, c: .elbow))
        #expect(spec.rep.polarity == .up && spec.rep.liftFirst)
        #expect(spec.rep.topPrior == 15 && spec.rep.bottomPrior == 160 && spec.rep.minRom == 80)
        #expect(spec.rep.dwellMs == 50 && spec.rep.minPeriodMs == 350 && spec.rep.maxPeriodMs == 6000)
        #expect(spec.rules.map(\.id) == ["armsHigh"])
        #expect(spec.rules.first?.cue == "cue.jumpingJack.armsUp")
        #expect(spec.rules.first?.severity == .major)
    }

    @Test("every bundled spec loads and validates", arguments: BundledSpec.allCases)
    func bundledLoads(which: BundledSpec) throws {
        let spec = try ExerciseSpec.bundled(which)
        try spec.validate()
        #expect(spec.id == which.rawValue)
    }

    @Test("every rule of a bundled spec names a cue localization key")
    func cueKeys() throws {
        for which in BundledSpec.allCases {
            for rule in try ExerciseSpec.bundled(which).rules {
                #expect(rule.cue.rawValue.hasPrefix("cue."), "\(rule.cue)")
            }
        }
    }

    // MARK: Codable

    @Test("encode then decode gives back an equal spec", arguments: BundledSpec.allCases)
    func roundTrip(which: BundledSpec) throws {
        let spec = try ExerciseSpec.bundled(which)
        let data = try JSONEncoder().encode(spec)
        #expect(try ExerciseSpec.decode(from: data) == spec)
    }

    @Test("every signal kind survives a round trip")
    func signalRoundTrip() throws {
        let signals: [SignalSpec] = [
            .jointAngle(a: .shoulder, b: .elbow, c: .wrist),
            .relativeHeight(of: .hip, to: .knee, scale: .shin),
            .exemplar(roles: [.shoulder, .hip, .knee], top: [0, 1, 0, -1], bottom: [1, 0, 1, -0.5]),
        ]
        for signal in signals {
            let data = try JSONEncoder().encode(signal)
            #expect(try JSONDecoder().decode(SignalSpec.self, from: data) == signal)
        }
    }

    @Test("optional rep parameters default when omitted")
    func repDefaults() throws {
        let json = #"{"polarity":"down","topPrior":1,"bottomPrior":0,"minRom":0.5}"#
        let rep = try JSONDecoder().decode(RepParameters.self, from: Data(json.utf8))
        #expect(rep.dwellMs == 70 && rep.minPeriodMs == 400 && rep.maxPeriodMs == 12_000 && rep.idleSeconds == 20)
        #expect(rep.topLeave == nil, "the engine's own threshold applies unless a spec sets one")
    }

    @Test("the squat spec raises the line where a descent begins, the push-up spec keeps the engine's")
    func topLeave() throws {
        #expect(try ExerciseSpec.bundled(.squatBodyweight).rep.topLeave == 0.65)
        #expect(try ExerciseSpec.bundled(.pushUp).rep.topLeave == nil)
        let rep = RepParameters(polarity: .down, topPrior: 1, bottomPrior: 0, minRom: 0.5, topLeave: 0.65)
        #expect(try JSONDecoder().decode(RepParameters.self, from: JSONEncoder().encode(rep)) == rep)
    }

    // MARK: Decoding errors

    private func bundledJSON(_ which: BundledSpec = .squatBodyweight) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: which.rawValue, withExtension: "json", subdirectory: "Specs"))
        return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> ExerciseSpec {
        try ExerciseSpec.decode(from: JSONSerialization.data(withJSONObject: object))
    }

    private func error(of object: [String: Any]) -> ExerciseSpecError? {
        do { _ = try decode(object); return nil } catch let e as ExerciseSpecError { return e } catch { return nil }
    }

    @Test("invalid JSON text is reported as malformed")
    func notJSON() {
        do {
            _ = try ExerciseSpec.decode(from: Data("{ nope".utf8))
            Testing.Issue.record("should have thrown")
        } catch let error as ExerciseSpecError {
            guard case .malformed = error else { Testing.Issue.record("wrong error \(error)"); return }
            #expect(error.errorDescription?.isEmpty == false)
        } catch {
            Testing.Issue.record("wrong error type \(error)")
        }
    }

    @Test("a missing required field names its path")
    func missingField() throws {
        var json = try bundledJSON()
        json["view"] = nil
        #expect(error(of: json) == .malformed(path: "view", reason: "required field is missing"))

        json = try bundledJSON()
        var rep = try #require(json["rep"] as? [String: Any])
        rep["minRom"] = nil
        json["rep"] = rep
        #expect(error(of: json) == .malformed(path: "rep.minRom", reason: "required field is missing"))
    }

    @Test("a missing version is reported")
    func missingVersion() throws {
        var json = try bundledJSON()
        json["version"] = nil
        #expect(error(of: json) == .malformed(path: "version", reason: "required field is missing"))
    }

    @Test("a wrong value names its path inside arrays")
    func wrongValue() throws {
        var json = try bundledJSON()
        var rules = try #require(json["rules"] as? [[String: Any]])
        rules[1]["op"] = "~="
        json["rules"] = rules
        let result = error(of: json)
        guard case let .malformed(path, _) = result else { Testing.Issue.record("got \(String(describing: result))"); return }
        #expect(path == "rules[1].op")
    }

    @Test("an unknown joint role or signal kind is malformed")
    func unknownEnum() throws {
        var json = try bundledJSON()
        json["requiredJoints"] = ["shoulder", "tail"]
        guard case let .malformed(path, _)? = error(of: json) else { Testing.Issue.record("expected malformed"); return }
        #expect(path == "requiredJoints[1]")

        json = try bundledJSON()
        json["signal"] = ["kind": "telepathy"]
        guard case let .malformed(path2, _)? = error(of: json) else { Testing.Issue.record("expected malformed"); return }
        #expect(path2 == "signal.kind")
    }

    @Test("a newer version is rejected before anything else is read", arguments: [2, 99, 0, -1])
    func unsupportedVersion(version: Int) throws {
        var json = try bundledJSON()
        json["version"] = version
        // Make the rest unreadable too: the version check has to win.
        json["signal"] = ["kind": "future"]
        #expect(error(of: json) == .unsupportedVersion(found: version, supported: 1))
    }

    // MARK: Validation

    private func problems(_ edit: (inout ExerciseSpec) -> Void) throws -> [String] {
        var spec = try squatSpec()
        edit(&spec)
        do { try spec.validate(); return [] } catch let ExerciseSpecError.invalid(list) { return list }
    }

    @Test("a valid spec has no problems")
    func valid() throws {
        #expect(try problems { _ in }.isEmpty)
    }

    @Test("validation names the path of each problem")
    func validationMessages() throws {
        #expect(try problems { $0.id = "  " }.contains("id: must not be empty"))
        #expect(try problems { $0.requiredJoints = [] }.contains("requiredJoints: must list at least one joint role"))
        #expect(try problems { $0.requiredJoints = [.shoulder, .hip, .knee, .ankle, .hip] }
            .contains("requiredJoints: contains duplicates"))
        #expect(try problems { $0.requiredJoints = [.shoulder, .hip, .ankle] }
            .contains("requiredJoints: must include 'knee' because the signal reads it"))
        #expect(try problems { $0.rep.minRom = 0 }.contains { $0.hasPrefix("rep.minRom: must be greater than 0") })
        #expect(try problems { $0.rep.topPrior = 0; $0.rep.bottomPrior = 1 }
            .contains("rep: polarity 'down' needs topPrior above bottomPrior"))
        #expect(try problems { $0.rep.polarity = .up }
            .contains("rep: polarity 'up' needs topPrior below bottomPrior"))
        #expect(try problems { $0.rep.minRom = 2 }.contains { $0.hasPrefix("rep: |topPrior − bottomPrior|") })
        #expect(try problems { $0.rep.dwellMs = 0 }.contains { $0.hasPrefix("rep.dwellMs") })
        #expect(try problems { $0.rep.maxPeriodMs = 300 }.contains("rep.maxPeriodMs: must exceed minPeriodMs"))
        #expect(try problems { $0.rep.topLeave = 0.9 }.contains { $0.hasPrefix("rep.topLeave") })
        #expect(try problems { $0.rep.topLeave = 0.3 }.contains { $0.hasPrefix("rep.topLeave") })
        #expect(try problems { $0.rep.idleSeconds = 1 }.contains { $0.hasPrefix("rep.idleSeconds") })
        #expect(try problems { $0.signal = .relativeHeight(of: .hip, to: .hip, scale: .thigh) }
            .contains("signal: relativeHeight 'of' and 'to' must differ"))
    }

    @Test("rules must reference listed metrics, unique ids, and sane cues")
    func ruleValidation() throws {
        #expect(try problems { $0.metrics = [.bottomValue] }
            .contains("rules[2].metric: 'eccMs' is not listed in metrics"))
        #expect(try problems { $0.rules[1].id = "depth" }.contains("rules: ids must be unique"))
        #expect(try problems { $0.rules[0].cue = "has space" }
            .contains("rules[0].cue: must be a non-empty key without spaces"))
        #expect(try problems { $0.rules[0].value = .infinity }.contains("rules[0].value: must be a finite number"))
    }

    @Test("score weights must name rules, stay in 0...1 and sum to at most 1")
    func scoreValidation() throws {
        #expect(try problems { $0.score["ghost"] = 0.1 }.contains("score: 'ghost' is not a rule id"))
        #expect(try problems { $0.score["depth"] = 1.5 }.contains { $0.hasPrefix("score.depth: weight must be between 0 and 1") })
        #expect(try problems { $0.score["depth"] = 0.9 }.contains("score: weights must sum to at most 1"))
    }

    @Test("a metric needs the joints it reads")
    func metricJoints() throws {
        let result = try problems {
            $0.metrics.append(.topElbowDeg)
        }
        #expect(result.contains("requiredJoints: must include 'elbow' because metric 'topElbowDeg' reads it"))
        #expect(result.contains("requiredJoints: must include 'wrist' because metric 'topElbowDeg' reads it"))
    }

    @Test("every problem is reported together, sorted")
    func collectsAll() throws {
        let result = try problems {
            $0.id = ""
            $0.rep.minRom = -1
            $0.rep.idleSeconds = 0
        }
        #expect(result.count >= 3)
        #expect(result == result.sorted())
    }

    @Test("exemplar specs are checked for dimension and distinctness")
    func exemplarValidation() throws {
        func spec(top: [Double], bottom: [Double], roles: [JointRole] = [.shoulder, .knee]) -> ExerciseSpec {
            ExerciseSpec(
                id: "taught", view: .any, requiredJoints: roles,
                signal: .exemplar(roles: roles, top: top, bottom: bottom),
                rep: RepParameters(polarity: .down, topPrior: 1, bottomPrior: 0, minRom: 0.4)
            )
        }
        #expect(throws: Never.self) { try spec(top: [0, 1, 0, -1], bottom: [1, 0, 1, -1]).validate() }
        do {
            try spec(top: [0, 1], bottom: [1, 0, 1, -1]).validate()
            Testing.Issue.record("short top should fail")
        } catch let ExerciseSpecError.invalid(list) {
            #expect(list.contains("signal.top: expected 4 numbers, found 2"))
        }
        do {
            try spec(top: [0, 1, 0, -1], bottom: [0, 1, 0, -1]).validate()
            Testing.Issue.record("identical poses should fail")
        } catch let ExerciseSpecError.invalid(list) {
            #expect(list.contains("signal: top and bottom poses must differ"))
        }
        do {
            try spec(top: [0], bottom: [1], roles: [.hip]).validate()
            Testing.Issue.record("hip-only should fail")
        } catch let ExerciseSpecError.invalid(list) {
            #expect(list.contains("signal.roles: need at least one joint besides the hip"))
        }
    }

    @Test("the pipeline refuses an invalid spec")
    func pipelineRejects() throws {
        var spec = try squatSpec()
        spec.rep.minRom = 0
        #expect(throws: ExerciseSpecError.self) { _ = try MotionPipeline(spec: spec) }
        #expect(throws: ExerciseSpecError.self) { _ = try MotionSession(spec: spec) }
    }

    @Test("error descriptions are readable")
    func descriptions() {
        #expect(ExerciseSpecError.unsupportedVersion(found: 7, supported: 1).errorDescription?.contains("7") == true)
        #expect(ExerciseSpecError.malformed(path: "rep.minRom", reason: "bad").errorDescription?.contains("rep.minRom") == true)
        #expect(ExerciseSpecError.invalid(["a", "b"]).errorDescription?.contains("- b") == true)
        #expect(ExerciseSpecError.resourceNotFound("x").errorDescription?.contains("x") == true)
    }

    @Test("metric keys with an at sign survive as JSON object keys")
    func metricKeyAsDictionaryKey() throws {
        let metrics: [MetricKey: Double] = [.maxTorsoLeanDegDescent: 41.5, .rom: 1.0]
        let data = try JSONEncoder().encode(metrics)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\"maxTorsoLeanDeg@descent\""))
        #expect(try JSONDecoder().decode([MetricKey: Double].self, from: data) == metrics)
    }
}
