import Foundation
import MotionCore
import Testing
@testable import MotionEval
@testable import PoseCapture

private struct CLIResult {
    var status: Int32
    var out: String
    var err: String
}

private func runCLI(_ arguments: [String]) async -> CLIResult {
    var out: [String] = []
    var err: [String] = []
    let status = await MotionEvalCLI.run(arguments: arguments, standardOutput: { out.append($0) }, standardError: { err.append($0) })
    return CLIResult(status: status, out: out.joined(separator: "\n"), err: err.joined(separator: "\n"))
}

private func writeFixture(
    _ motion: SyntheticMotion, to url: URL, specID: String?, labels: PoseLabels = PoseLabels()
) throws {
    let header = PoseFixtureHeader(exerciseSpecID: specID, cameraPosition: .unknown, fps: 30, labels: labels)
    try PoseFixtureFile.write(PoseFixture(header: header, frames: motion.frames()), to: url)
}

@Suite("motion-eval arguments")
struct EvalArgumentsTests {
    @Test func collectsPathsAndFlags() throws {
        let args = try EvalArguments.parse(["a.jsonl", "--synthetic", "clips", "--spec", "pushup", "--fps", "15"])
        #expect(args.paths == ["a.jsonl", "clips"])
        #expect(args.synthetic)
        #expect(args.specOverride == "pushup")
        #expect(args.maxFrameRate == 15)
        #expect(!args.help)
    }

    @Test func equalsFormsAndAllFrames() throws {
        let args = try EvalArguments.parse(["x.mov", "--spec=squat.bodyweight", "--fps=all"])
        #expect(args.specOverride == "squat.bodyweight")
        #expect(args.maxFrameRate == nil)
        #expect(try EvalArguments.parse(["x.mov", "--fps", "ALL"]).maxFrameRate == nil)
    }

    @Test func defaultsToThirtyFramesPerSecond() throws {
        #expect(try EvalArguments.parse(["x.mov"]).maxFrameRate == 30)
        #expect(try EvalArguments.parse(["x.mov"]).specOverride == nil)
    }

    @Test func syntheticAloneAndHelpAloneAreValid() throws {
        #expect(try EvalArguments.parse(["--synthetic"]).synthetic)
        #expect(try EvalArguments.parse(["--help"]).help)
        #expect(try EvalArguments.parse(["-h"]).help)
    }

    @Test func rejectsBadInput() {
        #expect(throws: EvalArgumentError.noInputs) { try EvalArguments.parse([]) }
        #expect(throws: EvalArgumentError.unknownOption("--bogus")) { try EvalArguments.parse(["--bogus"]) }
        #expect(throws: EvalArgumentError.missingValue("--spec")) { try EvalArguments.parse(["a.mov", "--spec"]) }
        #expect(throws: EvalArgumentError.missingValue("--fps")) { try EvalArguments.parse(["a.mov", "--fps"]) }
        #expect(throws: EvalArgumentError.badValue(option: "--fps", value: "fast")) { try EvalArguments.parse(["a.mov", "--fps", "fast"]) }
        #expect(throws: EvalArgumentError.badValue(option: "--fps", value: "0")) { try EvalArguments.parse(["a.mov", "--fps=0"]) }
        #expect(throws: EvalArgumentError.badValue(option: "--fps", value: "-5")) { try EvalArguments.parse(["a.mov", "--fps", "-5"]) }
    }

    @Test func usageDescribesTheFileNameConvention() {
        #expect(EvalArguments.usage.contains("squat.bodyweight_10.mov"))
        #expect(EvalArguments.usage.contains("pushup_8_2.mp4"))
        #expect(EvalArguments.usage.contains("--synthetic"))
    }
}

@Suite("motion-eval file names")
struct EvalFileNameTests {
    @Test("file name to exercise and counts", arguments: [
        ("squat.bodyweight_10.mov", "squat.bodyweight", 10 as Int?, nil as Int?),
        ("pushup_8_2.mp4", "pushup", 8, 2),
        ("squat_0.jsonl", "squat.bodyweight", 0, nil),
        ("squat_10_room2_front.mov", "squat.bodyweight", 10, nil),
        ("my_squat_5.mov", "squat.bodyweight", 5, nil),
        ("PushUps_12.MOV", "pushup", 12, nil),
        ("push-up_3_1.m4v", "pushup", 3, 1),
        ("squat.mov", "squat.bodyweight", nil, nil),
        ("jumpingjack_20.jsonl", "jumpingjack", 20, nil),
        ("Jumping-Jacks_16_4_front.mov", "jumpingjack", 16, 4),
        ("squat_x_3.mov", "squat.bodyweight", nil, nil),
        ("/some/dir/squat.bodyweight_7.mov", "squat.bodyweight", 7, nil),
    ] as [(String, String, Int?, Int?)])
    func parse(_ name: String, _ exercise: String, _ reps: Int?, _ partials: Int?) {
        let parsed = EvalFileName.parse(name)
        #expect(parsed.exerciseID == exercise)
        #expect(parsed.reps == reps)
        #expect(parsed.partials == partials)
    }

    @Test func unknownNamesGiveNothing() {
        #expect(EvalFileName.parse("clip_10.mov") == EvalFileName.Parsed())
        #expect(EvalFileName.parse("10.mov") == EvalFileName.Parsed())
    }
}

@Suite("motion-eval report")
struct EvalReportTests {
    private func row(
        _ name: String = "clip", expected: Int? = 10, partialsExpected: Int? = nil, counted: Int = 10, partials: Int = 0,
        score: Double? = 90, loss: Double? = 0.2
    ) -> EvalRow {
        EvalRow(
            name: name, exercise: "squat.bodyweight", expectedReps: expected, expectedPartials: partialsExpected,
            counted: counted, partials: partials, meanScore: score, velocityLoss: loss
        )
    }

    @Test func errorIsCountedMinusExpected() {
        #expect(row(expected: 10, counted: 9).error == -1)
        #expect(row(expected: 10, counted: 12).error == 2)
        #expect(row(expected: nil, counted: 4).error == nil)
        #expect(row(expected: 0, counted: 0).isIdle)
        #expect(!row(expected: nil, counted: 0).isIdle)
    }

    @Test func cellsShowSignedErrorsAndDashesForUnknowns() {
        #expect(EvalReport.cells(for: row(expected: 10, counted: 9))[5] == "-1")
        #expect(EvalReport.cells(for: row(expected: 10, counted: 12))[5] == "+2")
        #expect(EvalReport.cells(for: row(expected: 10, counted: 10))[5] == "0")
        let unknown = EvalReport.cells(for: row(expected: nil, counted: 4, score: nil, loss: nil))
        #expect(unknown[2] == "–" && unknown[5] == "–" && unknown[6] == "–" && unknown[7] == "–")
        #expect(EvalReport.cells(for: row(score: 87.46, loss: 0.2))[6] == "87.5")
        #expect(EvalReport.cells(for: row(loss: 0.2))[7] == "20%")
    }

    @Test func partialsShowAMismatchOnly() {
        #expect(EvalReport.partialsCell(for: row(partialsExpected: nil, partials: 3)) == "3")
        #expect(EvalReport.partialsCell(for: row(partialsExpected: 2, partials: 2)) == "2")
        #expect(EvalReport.partialsCell(for: row(partialsExpected: 2, partials: 3)) == "3 ≠ 2")
    }

    @Test func tableColumnsAreAligned() {
        let table = EvalReport.table(rows: [row("short"), row("a_much_longer_file_name.mov", counted: 8)])
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(Set(lines.map(\.count)).count == 1)
        #expect(lines[0].hasPrefix("| File"))
        #expect(lines[1].contains("---"))
        #expect(lines[1].contains(":"))                    // numeric columns are right-aligned
        #expect(lines[2].contains("short"))
        for line in lines { #expect(line.hasPrefix("| ") && line.hasSuffix(" |")) }
    }

    @Test func pipesInNamesAreEscaped() {
        let table = EvalReport.table(rows: [row("a|b.mov")])
        #expect(table.contains("a\\|b.mov"))
    }

    @Test func summaryCountsAccuracyAndFalseReps() {
        let rows = [
            row("exact1", expected: 10, counted: 10),
            row("exact2", expected: 8, counted: 8),
            row("off1", expected: 10, counted: 9),
            row("off3", expected: 10, counted: 13),
            row("idleOK", expected: 0, counted: 0),
            row("idleBad", expected: 0, counted: 2),
            row("unlabelled", expected: nil, counted: 5),
        ]
        let s = EvalSummary(rows: rows)
        #expect(s.clips == 7)
        #expect(s.labelled == 6)
        #expect(s.exact == 3)
        #expect(s.withinOne == 4)
        #expect(abs(s.meanAbsoluteError - (0 + 0 + 1 + 3 + 0 + 2) / 6.0) < 1e-12)
        #expect(s.idleClips == 2)
        #expect(s.falseReps == 2)
    }

    @Test func summaryCountsExactPartials() {
        let rows = [
            row(partialsExpected: 2, partials: 2), row(partialsExpected: 2, partials: 1), row(partialsExpected: nil, partials: 5),
        ]
        let s = EvalSummary(rows: rows)
        #expect(s.partialsLabelled == 2 && s.partialsExact == 1)
    }

    @Test func emptySummaryHasNoRates() {
        let lines = EvalReport.summaryLines(EvalSummary(rows: []), videoLatency: nil)
        let text = lines.joined(separator: "\n")
        #expect(text.contains("0 clips"))
        #expect(text.contains("Exact count: –"))
        #expect(text.contains("no idle clips"))
        #expect(!text.contains("latency"))
    }

    @Test func summaryTextAndLatencyLine() {
        let rows = [row(expected: 10, counted: 10), row(expected: 0, counted: 1)]
        let latency = LatencySummary(samples: [0.010, 0.012, 0.020])
        let text = EvalReport.markdown(rows: rows, videoLatency: latency)
        #expect(text.contains("Exact count: 1/2 (50%)"))
        #expect(text.contains("Off-by-one accuracy (within ±1 rep): 2/2 (100%)"))
        #expect(text.contains("Mean absolute error: 0.50 reps"))
        #expect(text.contains("False reps on idle clips: 1 over 1 idle clip"))
        #expect(text.contains("Vision latency"))
        #expect(text.contains("p50 12.0 ms"))
        #expect(text.contains("3 video frames"))
    }
}

@Suite("motion-eval runs")
struct MotionEvalRunTests {
    @Test func syntheticBenchmarkIsWellFormed() throws {
        let cases = SyntheticBenchmark.cases()
        #expect(cases.count >= 12)
        #expect(Set(cases.map(\.name)).count == cases.count)
        #expect(cases.contains { $0.expectedReps == 0 })                       // idle clips are part of the set
        #expect(cases.contains { $0.expectedPartials > 0 })
        #expect(Set(cases.map(\.spec)) == [.squatBodyweight, .pushUp, .jumpingJack])
    }

    @Test func syntheticRunCountsRepsAccurately() async throws {
        let result = await runCLI(["--synthetic"])
        #expect(result.status == 0)
        #expect(result.err.isEmpty)
        #expect(result.out.contains("## Synthetic benchmark"))
        #expect(result.out.contains("| File"))
        for item in SyntheticBenchmark.cases() { #expect(result.out.contains(item.name), "\(item.name)") }

        let rows = try EvalRunner.evaluateSynthetic()
        let summary = EvalSummary(rows: rows)
        #expect(summary.labelled == rows.count)
        // The clips are seeded and the engine is deterministic, so every clip is counted exactly: a row that
        // is off by one is a regression in the engine (or the eval), not noise.
        for row in rows {
            #expect(row.counted == row.expectedReps, "\(row.name): counted \(row.counted), expected \(row.expectedReps ?? -1)")
            #expect(row.partials == row.expectedPartials, "\(row.name): \(row.partials) partials, expected \(row.expectedPartials ?? -1)")
        }
        #expect(summary.exact == summary.labelled)
        #expect(summary.partialsExact == summary.partialsLabelled && summary.partialsLabelled == rows.count)
        #expect(summary.falseReps == 0)
        #expect(summary.idleClips >= 3)
    }

    @Test func syntheticRunIsDeterministic() async {
        let a = await runCLI(["--synthetic"])
        let b = await runCLI(["--synthetic"])
        #expect(a.out == b.out)
    }

    @Test func fixtureLabelsGiveTheExpectedCount() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("recorded-set.jsonl")
        try writeFixture(SyntheticMotion.squats(reps: 5, seed: 31), to: url, specID: "squat.bodyweight", labels: PoseLabels(reps: 5, partials: 0))

        let result = await runCLI([url.path])
        #expect(result.status == 0)
        #expect(result.out.contains("## Recordings"))
        let line = try #require(result.out.split(separator: "\n").first { $0.contains("recorded-set.jsonl") })
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(cells[0] == "recorded-set.jsonl")
        #expect(cells[1] == "squat.bodyweight")
        #expect(cells[2] == "5")                 // expected, from the labels
        #expect(cells[3] == "5")                 // counted
        #expect(cells[5] == "0")                 // error
    }

    @Test func fileNameIsUsedWhenTheFixtureHasNoLabelsOrSpec() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("pushup_4.jsonl")
        try writeFixture(SyntheticMotion.pushUps(reps: 4, seed: 32), to: url, specID: nil)
        let rows = await EvalRunner.evaluate(urls: [url], specOverride: nil, maxFrameRate: 30)
        #expect(rows.failures.isEmpty)
        let row = try #require(rows.rows.first)
        #expect(row.exercise == "pushup")
        #expect(row.expectedReps == 4)
        #expect(row.counted == 4)
    }

    @Test func labelsWinOverTheFileName() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat_9.jsonl")
        try writeFixture(SyntheticMotion.squats(reps: 6, seed: 33), to: url, specID: "squat.bodyweight", labels: PoseLabels(reps: 6))
        let outcome = await EvalRunner.evaluate(urls: [url], specOverride: nil, maxFrameRate: 30)
        #expect(outcome.rows.first?.expectedReps == 6)
    }

    @Test func specOverrideBeatsEverythingElse() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat_5.jsonl")
        try writeFixture(SyntheticMotion.squats(reps: 5, seed: 34), to: url, specID: "squat.bodyweight")
        let outcome = await EvalRunner.evaluate(urls: [url], specOverride: "pushup", maxFrameRate: 30)
        #expect(outcome.rows.first?.exercise == "pushup")
        #expect(outcome.rows.first?.counted == 0)
    }

    @Test func aSpecFileCanBeUsed() async throws {
        let directory = try TemporaryDirectory()
        let squat = try ExerciseSpec.bundled(.squatBodyweight)
        var custom = squat
        custom.id = "squat.custom"
        let specURL = directory.file("custom.json")
        try JSONEncoder().encode(custom).write(to: specURL)
        let url = directory.file("clip_5.jsonl")
        try writeFixture(SyntheticMotion.squats(reps: 5, seed: 38), to: url, specID: nil, labels: PoseLabels(reps: 5))

        let outcome = await EvalRunner.evaluate(urls: [url], specOverride: specURL.path, maxFrameRate: 30)
        #expect(outcome.failures.isEmpty, "\(outcome.failures)")
        #expect(outcome.rows.first?.exercise == "squat.custom")
        #expect(outcome.rows.first?.counted == 5)
    }

    @Test func unreadableAndUndeterminedInputsAreFailuresNotCrashes() async throws {
        let directory = try TemporaryDirectory()
        let noName = directory.file("clip.jsonl")
        try writeFixture(SyntheticMotion.squats(reps: 2), to: noName, specID: nil)
        let garbage = directory.file("garbage.jsonl")
        try Data("this is not json\n".utf8).write(to: garbage)
        let strange = directory.file("notes.txt")
        try Data("hello".utf8).write(to: strange)

        let outcome = await EvalRunner.evaluate(urls: [noName, garbage, strange], specOverride: nil, maxFrameRate: 30)
        #expect(outcome.rows.isEmpty)
        #expect(outcome.failures.map(\.name) == ["clip.jsonl", "garbage.jsonl", "notes.txt"])
        #expect(outcome.failures[0].reason.contains("cannot tell which exercise"))
        #expect(outcome.failures[2].reason.contains("unsupported file type"))
    }

    @Test func unknownSpecIDInTheHeaderFallsBackToTheFileName() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat_3.jsonl")
        try writeFixture(SyntheticMotion.squats(reps: 3, seed: 35), to: url, specID: "lunge.dumbbell")
        let outcome = await EvalRunner.evaluate(urls: [url], specOverride: nil, maxFrameRate: 30)
        #expect(outcome.rows.first?.exercise == "squat.bodyweight")
    }

    @Test func missingInputsGiveExitStatusOneButOtherFilesStillRun() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat_3.jsonl")
        try writeFixture(SyntheticMotion.squats(reps: 3, seed: 36), to: url, specID: nil)

        let result = await runCLI([directory.file("nope.mov").path, url.path])
        #expect(result.status == 1)
        #expect(result.err.contains("nope.mov"))
        #expect(result.err.contains("no such file"))
        #expect(result.out.contains("squat_3.jsonl"))
    }

    @Test func directoriesAreExpandedAndSorted() async throws {
        let directory = try TemporaryDirectory()
        try writeFixture(SyntheticMotion.squats(reps: 3, seed: 1), to: directory.file("squat_3_b.jsonl"), specID: nil)
        try writeFixture(SyntheticMotion.squats(reps: 3, seed: 2), to: directory.file("squat_3_a.jsonl"), specID: nil)
        try Data("ignore me".utf8).write(to: directory.file("README.txt"))
        try Data("hidden".utf8).write(to: directory.file(".hidden.jsonl"))

        let expanded = EvalRunner.expand([directory.url.path])
        #expect(expanded.failures.isEmpty)
        #expect(expanded.urls.map(\.lastPathComponent) == ["squat_3_a.jsonl", "squat_3_b.jsonl"])

        let result = await runCLI([directory.url.path])
        #expect(result.status == 0)
        let a = try #require(result.out.range(of: "squat_3_a.jsonl"))
        let b = try #require(result.out.range(of: "squat_3_b.jsonl"))
        #expect(a.lowerBound < b.lowerBound)
        #expect(!result.out.contains("README"))
    }

    @Test func usageErrorsReturnTwoAndHelpReturnsZero() async {
        let bad = await runCLI(["--bogus"])
        #expect(bad.status == 2)
        #expect(bad.err.contains("unknown option '--bogus'"))
        #expect(bad.err.contains("Usage: motion-eval"))
        #expect(bad.out.isEmpty)

        let none = await runCLI([])
        #expect(none.status == 2)

        let help = await runCLI(["--help"])
        #expect(help.status == 0)
        #expect(help.out.contains("Usage: motion-eval"))
    }

    @Test func recordingsAndSyntheticBenchmarkShareOneRun() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat_4.jsonl")
        try writeFixture(SyntheticMotion.squats(reps: 4, seed: 37), to: url, specID: nil)
        let result = await runCLI([url.path, "--synthetic"])
        #expect(result.status == 0)
        let recordings = try #require(result.out.range(of: "## Recordings"))
        let synthetic = try #require(result.out.range(of: "## Synthetic benchmark"))
        #expect(recordings.lowerBound < synthetic.lowerBound)
    }

    @Test(VisionHardware.bodyPose)
    func videosAreRunThroughVisionAndReportLatency() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat.bodyweight_0.mov")      // nobody in the picture: an idle clip
        try await TestMovie.write(to: url, width: 320, height: 240, frameCount: 20)

        let result = await runCLI([url.path])
        #expect(result.status == 0, "\(result.err)")
        let line = try #require(result.out.split(separator: "\n").first { $0.contains("squat.bodyweight_0.mov") })
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(cells[2] == "0" && cells[3] == "0" && cells[5] == "0")
        #expect(result.out.contains("False reps on idle clips: 0 over 1 idle clip"))
        #expect(result.out.contains("Vision latency"))
        #expect(result.out.contains("20 video frames"))
    }

    @Test func aBrokenVideoIsReportedAndSetsExitStatusOne() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat_3.mov")
        try Data("not a movie".utf8).write(to: url)
        let result = await runCLI([url.path])
        #expect(result.status == 1)
        #expect(result.err.contains("squat_3.mov"))
    }
}
