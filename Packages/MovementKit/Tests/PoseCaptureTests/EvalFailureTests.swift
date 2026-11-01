import CoreVideo
import Foundation
import ImageIO
import MotionCore
import Synchronization
import Testing
@testable import MotionEval
@testable import PoseCapture

private final class ControlledEstimator: PoseEstimating {
    struct Unavailable: Error {}
    let failingFrame: Int?
    let calls = Mutex(0)

    /// nil fails every frame; Int.max succeeds throughout a short test movie.
    init(failingFrame: Int?) { self.failingFrame = failingFrame }

    func measure(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                 mirrored: Bool, time: TimeInterval) async throws -> PoseEstimate {
        let index = calls.withLock { count in count += 1; return count }
        if failingFrame == nil || failingFrame == index { throw Unavailable() }
        return PoseEstimate(frame: PoseFrame(t: time, joints: [:], imageAspect: PoseGeometry.imageAspect(
            pixelWidth: CVPixelBufferGetWidth(pixelBuffer), pixelHeight: CVPixelBufferGetHeight(pixelBuffer), orientation: orientation)),
            peopleCount: 0, visionSeconds: 0.001)
    }
}

@Suite("Evaluation excludes missing measurements")
struct EvalFailureTests {
    @Test func aCompleteVisionOutageCannotBecomeAPerfectZeroRepClip() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat.bodyweight_0.mov")
        try await TestMovie.write(to: url, frameCount: 4)
        let result = await EvalRunner.evaluate(urls: [url], specOverride: nil, maxFrameRate: nil,
            videoEstimator: ControlledEstimator(failingFrame: nil))
        #expect(result.rows.isEmpty && result.videoLatencies.isEmpty)
        #expect(result.failures.count == 1)
        #expect(result.failures.first?.reason.contains("Vision failed on 4 of 4") == true)
    }

    @Test func evenAPartiallyFailedVideoIsExcludedFromAccuracyAndLatency() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("pushup_0.mov")
        try await TestMovie.write(to: url, frameCount: 4)
        let result = await EvalRunner.evaluate(urls: [url], specOverride: nil, maxFrameRate: nil,
            videoEstimator: ControlledEstimator(failingFrame: 2))
        #expect(result.rows.isEmpty && result.videoLatencies.isEmpty)
        #expect(result.failures.first?.reason.contains("Vision failed on 1 of 4") == true)
    }

    @Test func validEmptyObservationsStillCountAsMeasuredIdleFrames() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("pushup_0.mov")
        try await TestMovie.write(to: url, frameCount: 4)
        let result = await EvalRunner.evaluate(urls: [url], specOverride: nil, maxFrameRate: nil,
            videoEstimator: ControlledEstimator(failingFrame: Int.max))
        #expect(result.failures.isEmpty && result.rows.count == 1)
        #expect(result.rows.first?.counted == 0 && result.rows.first?.expectedReps == 0)
        #expect(result.videoLatencies.count == 4)
    }

    @Test func anEmptyLabelledFixtureCannotBecomeAPerfectZeroRepClip() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("squat.bodyweight_0.jsonl")
        let header = PoseFixtureHeader(exerciseSpecID: "squat.bodyweight", labels: PoseLabels(reps: 0))
        try PoseFixtureFile.write(PoseFixture(header: header, frames: []), to: url)
        let result = await EvalRunner.evaluate(urls: [url], specOverride: nil, maxFrameRate: nil)
        #expect(result.rows.isEmpty && result.failures.count == 1)
        #expect(result.failures.first?.reason.contains("no pose frames") == true)
    }
}
