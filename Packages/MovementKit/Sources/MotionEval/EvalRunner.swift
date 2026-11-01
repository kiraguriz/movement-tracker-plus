import Foundation
import MotionCore
import PoseCapture

/// An input that could not be evaluated. The run continues with the other inputs and exits non-zero.
struct EvalFailure: Equatable {
    var name: String
    var reason: String
}

/// What one evaluation of a set of inputs produced.
struct EvalOutcome {
    var rows: [EvalRow] = []
    var failures: [EvalFailure] = []
    /// Vision time per frame over all videos, in seconds.
    var videoLatencies: [Double] = []
}

enum EvalInputKind: Equatable {
    case fixture, video

    static let fixtureExtensions: Set<String> = ["jsonl"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    init?(url: URL) {
        let ext = url.pathExtension.lowercased()
        if Self.fixtureExtensions.contains(ext) {
            self = .fixture
        } else if Self.videoExtensions.contains(ext) {
            self = .video
        } else {
            return nil
        }
    }
}

enum EvalRunner {
    enum SpecError: Error, Equatable, LocalizedError {
        case unknownExercise(String)
        case undetermined

        var errorDescription: String? {
            switch self {
            case let .unknownExercise(id): "unknown exercise '\(id)'; use squat.bodyweight, pushup or the path of a spec .json"
            case .undetermined: "cannot tell which exercise this is: name the file like squat.bodyweight_10.mov or pass --spec"
            }
        }
    }

    // MARK: - Inputs

    /// Expands directories into their fixtures and videos (sorted by name, hidden files skipped, one level
    /// deep per directory and recursive below). Files are kept as given, so an unreadable or unsupported file
    /// is reported rather than silently dropped.
    static func expand(_ paths: [String]) -> (urls: [URL], failures: [EvalFailure]) {
        var urls: [URL] = []
        var failures: [EvalFailure] = []
        let fileManager = FileManager.default
        for path in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                failures.append(EvalFailure(name: path, reason: "no such file or directory"))
                continue
            }
            let url = URL(fileURLWithPath: path)
            guard isDirectory.boolValue else {
                urls.append(url)
                continue
            }
            let children = fileManager.enumerator(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )?.compactMap { $0 as? URL }.filter { EvalInputKind(url: $0) != nil } ?? []
            urls.append(contentsOf: children.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        }
        return (urls, failures)
    }

    // MARK: - Specs

    /// A bundled exercise by id or alias, or a spec `.json` file.
    static func spec(named identifier: String) throws -> ExerciseSpec {
        if let bundled = EvalFileName.aliases[identifier.lowercased()] ?? BundledSpec(rawValue: identifier) {
            return try ExerciseSpec.bundled(bundled)
        }
        if identifier.lowercased().hasSuffix(".json"), FileManager.default.fileExists(atPath: identifier) {
            return try ExerciseSpec.decode(from: Data(contentsOf: URL(fileURLWithPath: identifier)))
        }
        throw SpecError.unknownExercise(identifier)
    }

    /// The spec for an input: the override first, then the fixture header's id, then the file name.
    static func resolveSpec(override: String?, headerID: String?, fileName: EvalFileName.Parsed) throws -> ExerciseSpec {
        if let override { return try spec(named: override) }
        if let headerID, let found = try? spec(named: headerID) { return found }
        if let id = fileName.exerciseID { return try spec(named: id) }
        if let headerID { throw SpecError.unknownExercise(headerID) }
        throw SpecError.undetermined
    }

    // MARK: - Running

    /// Runs frames through a fresh pipeline and returns the set summary.
    static func summarize(_ frames: some Sequence<PoseFrame>, spec: ExerciseSpec) throws -> SetSummary {
        var pipeline = try MotionPipeline(spec: spec)
        for frame in frames { _ = pipeline.process(frame) }
        _ = pipeline.finish()
        return pipeline.summary
    }

    static func row(name: String, spec: ExerciseSpec, expectedReps: Int?, expectedPartials: Int?, summary: SetSummary) -> EvalRow {
        EvalRow(
            name: name, exercise: spec.id, expectedReps: expectedReps, expectedPartials: expectedPartials,
            counted: summary.reps, partials: summary.partials, meanScore: summary.averageScore,
            velocityLoss: summary.velocityLoss
        )
    }

    static func evaluateFixture(at url: URL, specOverride: String?) throws -> EvalRow {
        let fixture = try PoseFixtureFile.read(from: url)
        guard !fixture.frames.isEmpty else { throw EvalFailureReason("fixture contains no pose frames") }
        let name = url.lastPathComponent
        let parsed = EvalFileName.parse(name)
        let spec = try resolveSpec(override: specOverride, headerID: fixture.header.exerciseSpecID, fileName: parsed)
        let summary = try summarize(fixture.frames, spec: spec)
        return row(
            name: name, spec: spec,
            expectedReps: fixture.header.labels.reps ?? parsed.reps,
            expectedPartials: fixture.header.labels.partials ?? parsed.partials,
            summary: summary
        )
    }

    static func evaluateVideo(at url: URL, specOverride: String?, maxFrameRate: Double?,
                              estimator: any PoseEstimating = VisionPoseEstimator()) async throws -> (row: EvalRow, latencies: [Double]) {
        let name = url.lastPathComponent
        let parsed = EvalFileName.parse(name)
        let spec = try resolveSpec(override: specOverride, headerID: nil, fileName: parsed)
        var pipeline = try MotionPipeline(spec: spec)
        let source = VideoFilePoseSource(url: url, estimator: estimator, options: .init(maxFrameRate: maxFrameRate))
        for try await frame in source.frames() { _ = pipeline.process(frame) }
        guard source.framesDelivered > 0 else { throw EvalFailureReason("video produced no pose frames") }
        guard source.visionFailures == 0 else {
            throw EvalFailureReason("Vision failed on \(source.visionFailures) of \(source.framesDelivered) video frames; this clip cannot be scored")
        }
        _ = pipeline.finish()
        return (
            row(name: name, spec: spec, expectedReps: parsed.reps, expectedPartials: parsed.partials, summary: pipeline.summary),
            source.latencies
        )
    }

    static func evaluateSynthetic() throws -> [EvalRow] {
        try SyntheticBenchmark.cases().map { item in
            let spec = try ExerciseSpec.bundled(item.spec)
            let summary = try summarize(item.motion.frames(), spec: spec)
            return row(name: item.name, spec: spec, expectedReps: item.expectedReps, expectedPartials: item.expectedPartials, summary: summary)
        }
    }

    /// Evaluates every input in order. Failures are collected, never thrown.
    static func evaluate(urls: [URL], specOverride: String?, maxFrameRate: Double?,
                         videoEstimator: (any PoseEstimating)? = nil) async -> EvalOutcome {
        var outcome = EvalOutcome()
        for url in urls {
            let name = url.lastPathComponent
            do {
                guard let kind = EvalInputKind(url: url) else {
                    throw EvalFailureReason("unsupported file type '.\(url.pathExtension)' (expected .jsonl, .mov, .mp4 or .m4v)")
                }
                switch kind {
                case .fixture:
                    outcome.rows.append(try evaluateFixture(at: url, specOverride: specOverride))
                case .video:
                    let result = try await evaluateVideo(at: url, specOverride: specOverride, maxFrameRate: maxFrameRate,
                        estimator: videoEstimator ?? VisionPoseEstimator())
                    outcome.rows.append(result.row)
                    outcome.videoLatencies.append(contentsOf: result.latencies)
                }
            } catch {
                outcome.failures.append(EvalFailure(name: name, reason: error.localizedDescription))
            }
        }
        return outcome
    }
}

private struct EvalFailureReason: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
