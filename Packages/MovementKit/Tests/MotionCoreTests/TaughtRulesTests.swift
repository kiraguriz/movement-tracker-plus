import Foundation
import Testing
@testable import MotionCore

@Suite("Taught form checks")
struct TaughtRulesTests {
    private func demonstration(_ movement: TeachFigure.Movement = .lunge, reps: Int = 3, seed: UInt64 = 3, down: Double = 1.5) throws -> (
        result: TeachResult, spec: ExerciseSpec, take: TeachTake
    ) {
        let figure = TeachFigure(movement: movement, reps: TeachFigure.reps(reps, down: down), noise: .vision, seed: seed)
        let result = try teachResult(figure.frames())
        return (result, result.spec(id: "taught.test.aaaaaa"), result.take(confirming: reps))
    }

    private func analysis(_ seed: UInt64 = 3) throws -> TaughtAnalysis {
        let demo = try demonstration(seed: seed)
        return try TaughtSpecBuilder.analyze(baseline: demo.spec, take: demo.take)
    }

    private func check(_ template: String, _ threshold: Double, severity: Severity = .minor, weight: Double = 0.2) -> TaughtProposal.Check {
        TaughtProposal.Check(template: template, threshold: threshold, severity: severity, weight: weight)
    }

    // MARK: Menu

    @Test("the menu lists what the demonstration measured, with its own numbers")
    func menu() throws {
        let analysis = try analysis()
        let templates = analysis.menu.map(\.template)
        for basic in [TaughtRuleTemplate.reachBottom, .returnTop, .slowDown, .controlUp] {
            #expect(templates.contains(basic), "\(basic) is measurable in any demonstration")
        }
        for entry in analysis.menu {
            #expect(entry.observedMin <= entry.observedMedian && entry.observedMedian <= entry.observedMax)
            #expect(entry.observedMin.isFinite && entry.observedMax.isFinite)
        }
        let slow = try #require(analysis.menu.first { $0.template == .slowDown })
        #expect((1000...2200).contains(slow.observedMedian), "a 1.5 s descent, in milliseconds: \(slow.observedMedian)")
    }

    @Test("the template table is consistent")
    func table() {
        for template in TaughtRuleTemplate.allCases {
            #expect(template.range.lowerBound < template.range.upperBound)
            #expect(template.cue.rawValue.hasPrefix("cue."))
            #expect(!template.cue.rawValue.contains(" "))
            for role in template.extraJoints { #expect(template.metric.requiredRoles.contains(role)) }
        }
        #expect(Set(TaughtRuleTemplate.allCases.map(\.rawValue)).count == 7)
    }

    // MARK: Building

    @Test("a sensible proposal is kept and the spec passes the replay again")
    func accepted() throws {
        let analysis = try analysis()
        let proposal = TaughtProposal(checks: [
            check("slowDown", 900, weight: 0.3), check("returnTop", 0.8, weight: 0.2), check("reachBottom", 0.25, weight: 0.2),
        ])
        let build = TaughtSpecBuilder.build(analysis, proposal: proposal)
        let spec = try #require(build.spec, "dropped: \(build.dropped)")
        #expect(build.kept.map(\.template).sorted { $0.rawValue < $1.rawValue } == [.reachBottom, .returnTop, .slowDown])
        #expect(spec.rules.count == 3 && spec.score.count == 3)
        #expect(spec.score.values.reduce(0, +) <= TaughtSpecBuilder.maxTotalWeight + 1e-9)
        #expect(Set(spec.rules.map(\.cue.rawValue)).isSuperset(of: ["cue.controlDown", "cue.taught.returnFully", "cue.taught.deeper"]))

        // Gate 2 as a property of the result: same count, every demonstration rep without an issue.
        let take = analysis.take
        let verdict = try TaughtVerifier.verify(spec: spec, take: take)
        #expect(verdict.passed && verdict.counted == take.confirmedReps)
        #expect(verdict.reps.allSatisfy { $0.issues.isEmpty && $0.score == 100 })
    }

    @Test("a threshold the demonstration breaks is relaxed to the demonstration, never the reverse")
    func relaxed() throws {
        let analysis = try analysis()
        let entry = try #require(analysis.menu.first { $0.template == .reachBottom })
        // Demands a deeper bottom than the user's own reps reach.
        let strict = TaughtRuleTemplate.reachBottom.range.lowerBound
        let build = TaughtSpecBuilder.build(analysis, proposal: TaughtProposal(checks: [check("reachBottom", strict)]))
        if entry.observedMax > strict {
            let kept = try #require(build.kept.first, "dropped: \(build.dropped)")
            #expect(kept.wasRelaxed && kept.threshold > entry.observedMax, "\(kept) vs \(entry)")
            #expect(kept.proposedThreshold == strict)
        }
        if let spec = build.spec {
            let verdict = try TaughtVerifier.verify(spec: spec, take: analysis.take)
            #expect(verdict.passed)
        }
    }

    @Test("a timing check never asks for slower than the user's fastest rep")
    func timing() throws {
        let analysis = try analysis()
        let entry = try #require(analysis.menu.first { $0.template == .slowDown })
        let build = TaughtSpecBuilder.build(analysis, proposal: TaughtProposal(checks: [check("slowDown", 4000)]))
        if let kept = build.kept.first {
            #expect(kept.threshold <= entry.observedMin * TaughtSpecBuilder.timingShare + 0.001)
        } else {
            #expect(build.dropped.first?.reason == .demoViolates, "calibrating below the range drops the check")
        }
    }

    @Test("a check the demonstration cannot support is dropped for a reason")
    func rejections() throws {
        let analysis = try analysis()
        let build = TaughtSpecBuilder.build(analysis, proposal: TaughtProposal(checks: [
            check("kneeAngle", 90),
            check("returnTop", 0.2),
            check("returnTop", 0.8),
            check("slowDown", .nan),
            check("controlUp", 1000, weight: 0.9),
        ]))
        func reason(_ template: String) -> [TaughtDroppedCheck.Reason] { build.dropped.filter { $0.template == template }.map(\.reason) }
        #expect(reason("kneeAngle") == [.unknownTemplate])
        #expect(reason("returnTop") == [.outOfRange], "0.2 is outside 0.70 to 0.95, and the valid one after it is kept")
        #expect(reason("slowDown") == [.invalidNumbers])
        #expect(reason("controlUp") == [.invalidNumbers], "a weight of 0.9 is above the 0.5 limit")
        #expect(build.kept.map(\.template) == [.returnTop])
    }

    @Test("the same template twice keeps the first")
    func duplicates() throws {
        let build = TaughtSpecBuilder.build(try analysis(), proposal: TaughtProposal(checks: [check("returnTop", 0.8), check("returnTop", 0.9)]))
        #expect(build.dropped.map(\.reason) == [.duplicate] && build.kept.count == 1)
    }

    @Test("at most three checks are kept and the rest are named as too many")
    func tooMany() throws {
        let analysis = try analysis()
        let build = TaughtSpecBuilder.build(analysis, proposal: TaughtProposal(checks: [
            check("returnTop", 0.8, weight: 0.1), check("reachBottom", 0.25, weight: 0.1), check("slowDown", 800, weight: 0.1),
            check("controlUp", 600, weight: 0.1),
        ]))
        #expect(build.kept.count <= TaughtSpecBuilder.maxChecks)
        #expect(build.dropped.contains { $0.template == "controlUp" && $0.reason == .tooMany })
    }

    @Test("a template that cannot be measured here is not accepted")
    func unmeasurable() throws {
        // A curl in the side view never has the ankle-to-shoulder line the check reads... and a lunge has no
        // elbow movement: whichever templates are missing from the menu must be refused by name.
        let analysis = try analysis()
        let missing = Set(TaughtRuleTemplate.allCases).subtracting(analysis.menu.map(\.template))
        for template in missing {
            let build = TaughtSpecBuilder.build(analysis, proposal: TaughtProposal(checks: [check(template.rawValue, template.range.lowerBound + 1)]))
            #expect(build.dropped.first?.reason == .notMeasurable)
            #expect(build.spec == nil)
        }
    }

    @Test("no proposal at all leaves nothing to build")
    func empty() throws {
        let build = TaughtSpecBuilder.build(try analysis(), proposal: TaughtProposal(checks: []))
        #expect(build.spec == nil && build.kept.isEmpty)
    }

    // MARK: The property

    /// Whatever a model writes, a spec that comes out passes its own demonstration: the same count, no rep marked
    /// as bad. The proposals here are random, including out-of-range and nonsense ones.
    @Test("for any proposal the built spec accepts the demonstration", arguments: [1, 2, 3, 4, 5, 6, 7, 8] as [UInt64])
    func demonstrationAlwaysPasses(seed: UInt64) throws {
        let analysis = try analysis(seed % 3 + 1)
        var rng = SplitMix64(seed: seed)
        let names = TaughtRuleTemplate.allCases.map(\.rawValue) + ["bogus"]
        for _ in 0..<6 {
            var checks: [TaughtProposal.Check] = []
            for _ in 0..<Int(rng.next() % 5) {
                let name = names[Int(rng.next() % UInt64(names.count))]
                let template = TaughtRuleTemplate(rawValue: name)
                let range = template?.range ?? 0...1
                let unit = Double(rng.next() % 1000) / 1000
                let threshold = range.lowerBound - (range.upperBound - range.lowerBound) * 0.1 + unit * (range.upperBound - range.lowerBound) * 1.2
                checks.append(check(
                    name, threshold, severity: rng.next() % 2 == 0 ? .minor : .major, weight: 0.02 + Double(rng.next() % 600) / 1000
                ))
            }
            let build = TaughtSpecBuilder.build(analysis, proposal: TaughtProposal(checks: checks))
            #expect(build.kept.count <= TaughtSpecBuilder.maxChecks)
            guard let spec = build.spec else { continue }
            let verdict = try TaughtVerifier.verify(spec: spec, take: analysis.take)
            #expect(verdict.passed, "seed \(seed): \(checks) -> \(build.kept) / \(verdict.failure.map(String.init(describing:)) ?? "")")
            #expect(verdict.reps.allSatisfy { $0.issues.isEmpty })
            #expect(spec.rules.allSatisfy { rule in TaughtRuleTemplate(rawValue: rule.id)?.range.contains(rule.value) == true })
            #expect(spec.score.values.reduce(0, +) <= TaughtSpecBuilder.maxTotalWeight + 1e-9)
            #expect((try? spec.validate()) != nil)
        }
    }

    // MARK: A check that checks

    @Test("a kept check catches a worse set than the demonstration")
    func catchesWorseReps() throws {
        let analysis = try analysis()
        let build = TaughtSpecBuilder.build(analysis, proposal: TaughtProposal(checks: [check("slowDown", 1300, severity: .major, weight: 0.4)]))
        let spec = try #require(build.spec, "dropped: \(build.dropped)")

        // The same movement dropped twice as fast: the count is the same, the check is not met.
        let fast = try demonstration(reps: 3, seed: 4, down: 0.55)
        let verdict = try TaughtVerifier.verify(spec: spec, take: fast.take)
        guard case .ruleFailsDemo(let rule, let violations, _) = try #require(verdict.failure, "\(verdict)") else {
            Issue.record("expected a rule failure, got \(String(describing: verdict.failure))")
            return
        }
        #expect(rule == "slowDown" && violations >= 1)
    }

    @Test("a curl demonstration builds checks too")
    func curl() throws {
        let demo = try demonstration(.curl, reps: 3, seed: 5)
        let analysis = try TaughtSpecBuilder.analyze(baseline: demo.spec, take: demo.take)
        #expect(!analysis.menu.isEmpty)
        let build = TaughtSpecBuilder.build(analysis, proposal: TaughtProposal(checks: [check("controlUp", 600)]))
        if let spec = build.spec {
            #expect(try TaughtVerifier.verify(spec: spec, take: demo.take).passed)
        }
    }

    @Test("the summary states the demonstration in numbers")
    func summary() throws {
        let demo = try demonstration()
        let analysis = try TaughtSpecBuilder.analyze(baseline: demo.spec, take: demo.take)
        let summary = DemoSummary(result: demo.result, reps: analysis.reps, confirmedReps: 3)
        #expect(summary.reps == 3 && summary.durationSeconds > 5)
        #expect(summary.medianLowerMs > 500 && summary.medianRaiseMs > 500)
        let knee = try #require(summary.startPose.knee)
        #expect(knee > 120, "a standing knee is nearly straight: \(knee)")
        let data = try JSONEncoder().encode(summary)
        #expect(data.count < 1500, "a few hundred bytes of numbers, not a recording")
    }
}
