import Foundation
import Testing
@testable import MotionCore

/// Everything a pipeline produced over a run.
struct RunResult {
    var events: [MotionEvent]
    var summary: SetSummary

    var reps: [RepRecord] { summary.records }
    var partials: [RepRecord] { summary.partialRecords }
    var cues: [CueKey] { events.compactMap { if case let .cue(c) = $0 { c } else { nil } } }
    var idleCount: Int { events.filter { $0 == .idle }.count }
    var framingStates: [FramingState] { events.compactMap { if case let .framing(s) = $0 { s } else { nil } } }
    var phases: [Phase] { events.compactMap { if case let .phase(p) = $0 { p } else { nil } } }
}

func squatSpec() throws -> ExerciseSpec { try ExerciseSpec.bundled(.squatBodyweight) }
func pushUpSpec() throws -> ExerciseSpec { try ExerciseSpec.bundled(.pushUp) }
func jumpingJackSpec() throws -> ExerciseSpec { try ExerciseSpec.bundled(.jumpingJack) }

/// Runs frames through a fresh pipeline, finishing the stream at the end.
func run(_ frames: [PoseFrame], spec: ExerciseSpec, config: MotionConfig = .default) throws -> RunResult {
    var pipeline = try MotionPipeline(spec: spec, config: config)
    var events: [MotionEvent] = []
    for frame in frames { events += pipeline.process(frame) }
    events += pipeline.finish()
    return RunResult(events: events, summary: pipeline.summary)
}

func run(_ motion: SyntheticMotion, spec: ExerciseSpec? = nil, config: MotionConfig = .default) throws -> RunResult {
    let resolved: ExerciseSpec
    if let spec {
        resolved = spec
    } else {
        switch motion.exercise {
        case .squat: resolved = try squatSpec()
        case .pushUp: resolved = try pushUpSpec()
        case .jumpingJack: resolved = try jumpingJackSpec()
        }
    }
    return try run(motion.frames(), spec: resolved, config: config)
}
