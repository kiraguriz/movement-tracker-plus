import Foundation
import MotionCore
import PoseCapture

// Writes `replay-<name>.jsonl` for each clip below, then replays every written file through the engine and
// fails unless it counts exactly the reps and partial reps the clip scripts. The clips are seeded, so a rerun
// writes the same bytes.

struct Clip {
    var name: String
    var spec: BundledSpec
    var motion: SyntheticMotion
    var reps: Int
    var partials: Int
    var notes: String
}

let noise = SyntheticMotion.Noise.visionLike

// Ten squats and one partial. The partial comes after rep 4, so once the counter shows 10 only the final
// standing frames remain. Reps 3, 7 and 8 break a rule each (chest, tempo, depth) so a review has something
// to say; the last reps get slower, which gives the set a velocity loss.
let squat = Clip(
    name: "squat",
    spec: .squatBodyweight,
    motion: SyntheticMotion(
        exercise: .squat,
        actions: [
            .rep(.squat()),
            .rep(.squat()),
            .rep(.squat(torsoLeanDeg: 58)),
            .rep(.squat()),
            .rep(.partialSquat()),
            .rep(.squat()),
            .rep(.squat()),
            .rep(.squat(eccentric: 0.5, concentric: 1.0)),
            .rep(.squat(bottom: 0.14, concentric: 1.35)),
            .rep(.squat(eccentric: 1.6, concentric: 1.55)),
            .rep(.squat(eccentric: 1.7, concentric: 1.7)),
        ],
        facing: .right, noise: noise, seed: 4101
    ),
    reps: 10,
    partials: 1,
    notes: "Synthetic squat set: 10 counted reps and 1 partial."
)

// Eight push-ups and one partial in the middle.
let pushUp = Clip(
    name: "pushup",
    spec: .pushUp,
    motion: SyntheticMotion(
        exercise: .pushUp,
        actions: [
            .rep(.pushUp()),
            .rep(.pushUp()),
            .rep(.pushUp()),
            .rep(.partialPushUp()),
            .rep(.pushUp()),
            .rep(.pushUp(eccentric: 1.5, concentric: 1.4)),
            .rep(.pushUp(eccentric: 1.6, concentric: 1.6)),
            .rep(.pushUp(eccentric: 1.7, concentric: 1.8)),
            .rep(.pushUp(eccentric: 1.8, concentric: 1.9)),
        ],
        facing: .right, noise: noise, seed: 4201
    ),
    reps: 8,
    partials: 1,
    notes: "Synthetic push-up set: 8 counted reps and 1 partial."
)

// Fifteen front-view jumping jacks and two partials. Reps 5 and 6 stop the arms at 130 degrees (the arms-high
// rule fires), the partials stop at shoulder height, and the last reps get slower.
let jumpingJack = Clip(
    name: "jumpingjack",
    spec: .jumpingJack,
    motion: SyntheticMotion(
        exercise: .jumpingJack,
        actions: [
            .rep(.jumpingJack()),
            .rep(.jumpingJack()),
            .rep(.jumpingJack()),
            .rep(.jumpingJack()),
            .rep(.jumpingJack(peak: 130)),
            .rep(.jumpingJack(peak: 130)),
            .rep(.partialJumpingJack()),
            .rep(.jumpingJack()),
            .rep(.jumpingJack()),
            .rep(.jumpingJack()),
            .rep(.partialJumpingJack()),
            .rep(.jumpingJack()),
            .rep(.jumpingJack(raise: 0.5, lower: 0.5)),
            .rep(.jumpingJack(raise: 0.55, lower: 0.5)),
            .rep(.jumpingJack(raise: 0.6, lower: 0.5)),
            .rep(.jumpingJack(raise: 0.65, lower: 0.5)),
            .rep(.jumpingJack(raise: 0.7, lower: 0.5)),
        ],
        facing: .right, noise: noise, seed: 4301
    ),
    reps: 15,
    partials: 2,
    notes: "Synthetic front-view jumping jack set: 15 counted reps and 2 partials."
)

func run() async -> Int32 {
    guard let directory = CommandLine.arguments.dropFirst().first else {
        FileHandle.standardError.write(Data("usage: replay-fixtures <output directory>\n".utf8))
        return 2
    }
    let output = URL(fileURLWithPath: directory, isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("cannot create \(directory): \(error)\n".utf8))
        return 1
    }

    var failed = false
    for clip in [squat, pushUp, jumpingJack] {
        let frames = clip.motion.frames()
        let header = PoseFixtureHeader(
            exerciseSpecID: clip.spec.rawValue,
            cameraPosition: .unknown,
            fps: clip.motion.timing.fps,
            deviceModel: "synthetic",
            created: Date(timeIntervalSince1970: 1_767_225_600),
            labels: PoseLabels(reps: clip.reps, partials: clip.partials, notes: clip.notes, tags: ["synthetic", "replay"])
        )
        let url = output.appending(path: "replay-\(clip.name).jsonl", directoryHint: .notDirectory)
        do {
            try PoseFixtureFile.write(PoseFixture(header: header, frames: frames), to: url)
            let counted = try await count(url: url, spec: clip.spec)
            let ok = counted.reps == clip.reps && counted.partials == clip.partials
            print("\(ok ? "ok  " : "FAIL") replay-\(clip.name).jsonl  frames \(frames.count)  \(String(format: "%.1f", clip.motion.duration)) s  counted \(counted.reps) reps, \(counted.partials) partial (expected \(clip.reps), \(clip.partials))")
            if !ok { failed = true }
        } catch {
            print("FAIL replay-\(clip.name).jsonl: \(error)")
            failed = true
        }
    }
    return failed ? 1 : 0
}

func count(url: URL, spec: BundledSpec) async throws -> (reps: Int, partials: Int) {
    let fixture = try PoseFixtureFile.read(from: url)
    let session = try MotionSession(spec: try .bundled(spec))
    for frame in fixture.frames { await session.process(frame) }
    let summary = await session.finish()
    return (summary.reps, summary.partials)
}

exit(await run())
