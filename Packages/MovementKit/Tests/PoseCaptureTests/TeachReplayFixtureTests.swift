import Foundation
import MotionCore
import Testing
@testable import PoseCapture

/// Teaching from the bundled squat recording, the way the Simulator's replay feed presents it: standing, then
/// three reps, then standing again.
@Suite("Teach from the bundled squat recording")
struct TeachReplayFixtureTests {
    static func load() throws -> PoseFixture {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "App/Resources/ReplayPoses/replay-squat.jsonl")
        return try PoseFixtureFile.read(from: url)
    }

    @Test func threeRepsOfTheRecordingVerify() async throws {
        let fixture = try Self.load()
        var pipeline = try MotionPipeline(spec: .bundled(.squatBodyweight))
        var ends: [Double] = []
        var firstStart: Double?
        for frame in fixture.frames {
            for event in pipeline.process(frame) {
                if case .repCompleted(let record) = event {
                    ends.append(record.tEnd)
                    firstStart = firstStart ?? record.tStart
                }
            }
        }
        let first = try #require(fixture.frames.first)
        let start = max(first.t + 1, (firstStart ?? first.t + 2) - 0.5)
        let cut = ends[2] + 1
        let standing = fixture.frames.filter { $0.t < start }
        let demo = fixture.frames.filter { $0.t >= start && $0.t <= cut }

        var clock = first.t
        var stream: [PoseFrame] = []
        func emit(_ frame: PoseFrame, step: Double) {
            clock += step
            var copy = frame
            copy.t = clock
            stream.append(copy)
        }
        for index in 0..<(30 * 4) { emit(standing[index % standing.count], step: 1.0 / 30) }
        for (index, frame) in demo.enumerated() {
            emit(frame, step: index > 0 ? max(0.001, frame.t - demo[index - 1].t) : 1.0 / 30)
        }
        for index in 0..<(30 * 2) { emit(standing[index % standing.count], step: 1.0 / 30) }

        let session = TeachSession()
        await session.beginTake()
        for (index, frame) in stream.enumerated() {
            await session.process(frame)
            if index == 90 { await session.beginAnalysis() }
        }
        let result = try await session.finish()
        #expect(result.detectedReps == 3)
        let outcome = try TaughtVerifier.verifyChoosingView(spec: result.spec(id: "taught.test.aaaaaa"), take: result.take(confirming: 3))
        #expect(outcome.verification.passed)
    }
}
