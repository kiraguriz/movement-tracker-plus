import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import MotionCore
import Testing
@testable import PoseCapture

@Suite("Video file source")
struct VideoFilePoseSourceTests {
    private func collect(_ source: VideoFilePoseSource) async throws -> [PoseFrame] {
        var frames: [PoseFrame] = []
        for try await frame in source.frames() { frames.append(frame) }
        return frames
    }

    @Test(.enabled(if: VisionHardware.supportsBodyPose, "Requires a Vision body-pose compute device"))
    func deliversEveryFrameWithItsPresentationTime() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("plain.mov")
        try await TestMovie.write(to: url, width: 320, height: 240, frameCount: 30, fps: 30)

        let source = VideoFilePoseSource(url: url, options: .init(maxFrameRate: nil))
        let frames = try await collect(source)

        #expect(frames.count == 30)
        for (i, frame) in frames.enumerated() {
            #expect(abs(frame.t - Double(i) / 30) < 1e-6, "frame \(i)")
        }
        #expect(frames.allSatisfy { abs($0.imageAspect - 320.0 / 240) < 1e-9 })
        #expect(frames.allSatisfy { $0.joints.isEmpty })        // nobody in a grey picture
        #expect(source.framesDelivered == 30)
        #expect(source.framesWithPerson == 0)
        #expect(source.framesSkipped == 0)
        #expect(source.visionFailures == 0)
        #expect(source.latencies.count == 30)
        #expect(source.latency.count == 30)
        #expect(source.latency.p50 > 0)
        #expect(source.latency.p95 >= source.latency.p50)
    }

    @Test func downsamplesToTheFrameRateCap() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("sixty.mov")
        try await TestMovie.write(to: url, frameCount: 60, fps: 60)

        let source = VideoFilePoseSource(url: url, options: .init(maxFrameRate: 30))
        let frames = try await collect(source)
        #expect(frames.count == 30)
        #expect(source.framesSkipped == 30)
        // Spacing is about 1/30 s, no frame closer than 80 % of that.
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(b.t - a.t >= 0.8 / 30 - 1e-9)
            #expect(b.t > a.t)
        }
        #expect(abs((frames.last?.t ?? 0) - (frames.first?.t ?? 0) - 29.0 / 30) < 0.05)
    }

    @Test func aCapAboveTheRecordedRateKeepsEveryFrame() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("thirty.mov")
        try await TestMovie.write(to: url, frameCount: 30, fps: 30)
        let frames = try await collect(VideoFilePoseSource(url: url, options: .init(maxFrameRate: 30)))
        #expect(frames.count == 30)
    }

    @Test func maxFramesStopsTheStream() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("many.mov")
        try await TestMovie.write(to: url, frameCount: 30)
        let frames = try await collect(VideoFilePoseSource(url: url, options: .init(maxFrameRate: nil, maxFrames: 7)))
        #expect(frames.count == 7)
    }

    @Test func portraitTransformGivesAnUprightAspect() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("portrait.mov")
        // Stored landscape 320x240, flagged to be shown turned a quarter: the way an iPhone stores portrait video.
        try await TestMovie.write(to: url, width: 320, height: 240, frameCount: 5, transform: TestMovie.portraitTransform(storedHeight: 240))

        let source = VideoFilePoseSource(url: url, options: .init(maxFrameRate: nil))
        let info = try await source.info()
        #expect(info.orientation == .right)
        #expect(info.pixelSize == CGSize(width: 320, height: 240))
        #expect(abs(info.imageAspect - 240.0 / 320) < 1e-9)

        let frames = try await collect(source)
        #expect(frames.count == 5)
        #expect(frames.allSatisfy { abs($0.imageAspect - 0.75) < 1e-9 })
    }

    @Test func infoDescribesTheFile() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("info.mov")
        try await TestMovie.write(to: url, width: 320, height: 240, frameCount: 45, fps: 30)
        let info = try await VideoFilePoseSource(url: url).info()
        #expect(info.orientation == .up)
        #expect(abs(info.duration - 1.5) < 0.05)
        #expect(abs(info.nominalFrameRate - 30) < 1)
        #expect(abs(info.imageAspect - 320.0 / 240) < 1e-9)
    }

    @Test func aFileThatIsNotAVideoThrows() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("fake.mov")
        try Data("this is not a movie".utf8).write(to: url)
        await #expect(throws: (any Error).self) { _ = try await collect(VideoFilePoseSource(url: url)) }
    }

    @Test func aMissingFileThrows() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("missing.mov")
        await #expect(throws: (any Error).self) { _ = try await collect(VideoFilePoseSource(url: url)) }
    }

    @Test(.enabled(if: VisionHardware.supportsBodyPose, "Requires a Vision body-pose compute device"))
    func statisticsResetWhenReadingAgain() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.file("twice.mov")
        try await TestMovie.write(to: url, frameCount: 12)
        let source = VideoFilePoseSource(url: url, options: .init(maxFrameRate: nil))
        _ = try await collect(source)
        _ = try await collect(source)
        #expect(source.framesDelivered == 12)
        #expect(source.latencies.count == 12)
    }
}
