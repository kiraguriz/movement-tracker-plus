import CoreGraphics
import CoreVideo
import Dispatch
import Foundation
import ImageIO
import MotionCore
import Synchronization
import Vision

/// The outcome of one Vision call.
public struct PoseEstimate: Sendable {
    /// The frame to feed downstream. Its joints are empty when nobody was found, so a stream of
    /// estimates keeps a steady cadence and MotionCore sees "no person" rather than a gap.
    public var frame: PoseFrame
    /// How many people Vision found (the frame holds the most prominent one).
    public var peopleCount: Int
    /// Wall-clock seconds spent in the Vision request itself.
    public var visionSeconds: Double
    /// Every person with at least one usable joint, in PoseFrame space. `PersonTracker` chooses among
    /// them over time (`frame(following:)`); `frame` is only the most prominent one of this image.
    public var people: [[MotionCore.Joint: Keypoint]] = []

    public var personFound: Bool { !frame.joints.isEmpty }
}

public enum PoseEstimatorError: Error, Equatable, Sendable {
    case visionFailed(String)
    case timedOut
}

/// The video reader can be checked with deterministic estimators without a camera or GPU.
public protocol PoseEstimating: Sendable {
    func measure(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                 mirrored: Bool, time: TimeInterval) async throws -> PoseEstimate
}

/// Turns images into `PoseFrame`s with Vision's 2D body pose (the Swift `DetectHumanBodyPoseRequest`,
/// revision 2, 19 joints). Stateless and `Sendable`: share one instance.
///
/// Coordinates: see `PoseGeometry`. Vision reports joints in the oriented image, so pass the orientation
/// that makes the image upright and `mirrored: true` for a mirrored (front camera) preview.
///
/// The Swift Vision API is `async` only; the old `VNDetectHumanBodyPoseRequest` is a different model
/// (revision 1) with different joint positions. `measure` is the async entry point; `measureBlocking`
/// bridges it for a capture queue, where the pixel buffer must not outlive the delegate callback.
public final class VisionPoseEstimator: PoseEstimating {
    public struct Options: Equatable, Sendable {
        /// Joints with confidence at or below this are treated as not found.
        public var dropConfidenceAtOrBelow: Double = 0
        /// Joints below this confidence do not count when choosing the most prominent person.
        public var prominenceConfidence: Double = 0.3

        public init(dropConfidenceAtOrBelow: Double = 0, prominenceConfidence: Double = 0.3) {
            self.dropConfidenceAtOrBelow = dropConfidenceAtOrBelow
            self.prominenceConfidence = prominenceConfidence
        }
    }

    public let options: Options
    private let request: DetectHumanBodyPoseRequest
    private let bridge = BlockingBridge()

    public init(options: Options = Options()) {
        var request = DetectHumanBodyPoseRequest()
        request.detectsHands = false
        self.request = request
        self.options = options
    }

    // MARK: - Async

    /// The most prominent person's pose, or nil when Vision found nobody.
    public func estimate(
        pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, mirrored: Bool = false, time: TimeInterval
    ) async throws -> PoseFrame? {
        let estimate = try await measure(pixelBuffer: pixelBuffer, orientation: orientation, mirrored: mirrored, time: time)
        return estimate.personFound ? estimate.frame : nil
    }

    public func estimate(
        image: CGImage, orientation: CGImagePropertyOrientation = .up, mirrored: Bool = false, time: TimeInterval = 0
    ) async throws -> PoseFrame? {
        let estimate = try await measure(image: image, orientation: orientation, mirrored: mirrored, time: time)
        return estimate.personFound ? estimate.frame : nil
    }

    /// Like `estimate`, but always returns a frame (empty when nobody was found) together with timing.
    public func measure(
        pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, mirrored: Bool = false, time: TimeInterval
    ) async throws -> PoseEstimate {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let result = try await perform { try await request.perform(on: pixelBuffer, orientation: orientation) }
        return assemble(result, time: time, width: width, height: height, orientation: orientation, mirrored: mirrored)
    }

    public func measure(
        image: CGImage, orientation: CGImagePropertyOrientation = .up, mirrored: Bool = false, time: TimeInterval = 0
    ) async throws -> PoseEstimate {
        let result = try await perform { try await request.perform(on: image, orientation: orientation) }
        return assemble(result, time: time, width: image.width, height: image.height, orientation: orientation, mirrored: mirrored)
    }

    // MARK: - Blocking bridge for a capture queue

    /// Runs `measure` and waits for it, for use on a serial capture queue (never on the main thread or
    /// inside Swift concurrency; both are asserted against in debug builds). The calling thread blocks
    /// until Vision is done, so the pixel buffer stays on the queue exactly as long as it is needed. Nil on
    /// a Vision failure, after `timeout`, or while an earlier call that timed out is still running.
    public func measureBlocking(
        pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .up, mirrored: Bool = false,
        time: TimeInterval, timeout: TimeInterval = 2
    ) -> PoseEstimate? {
        let input = UncheckedSendable(pixelBuffer)
        return bridge.run(timeout: timeout) { [self] in
            try? await measure(pixelBuffer: input.value, orientation: orientation, mirrored: mirrored, time: time)
        }
    }

    // MARK: - Internals

    /// Runs a Vision call, timing the attempt that counts. See `VisionRetryPolicy` for what is retried.
    private func perform(
        _ body: () async throws -> [HumanBodyPoseObservation]
    ) async throws -> (observations: [HumanBodyPoseObservation], seconds: Double) {
        var seconds = 0.0
        let observations = try await VisionRetryPolicy.run {
            let start = ContinuousClock.now
            let result = try await body()
            seconds = (ContinuousClock.now - start).seconds
            return result
        }
        return (observations, seconds)
    }

    private func assemble(
        _ result: (observations: [HumanBodyPoseObservation], seconds: Double), time: TimeInterval,
        width: Int, height: Int, orientation: CGImagePropertyOrientation, mirrored: Bool
    ) -> PoseEstimate {
        var people: [[PoseJoint: VisionJointSample]] = []
        people.reserveCapacity(result.observations.count)
        for observation in result.observations {
            var samples: [PoseJoint: VisionJointSample] = [:]
            for (name, joint) in observation.allJoints() {
                guard let mapped = PoseAssembly.joint(for: name) else { continue }
                samples[mapped] = VisionJointSample(
                    x: Double(joint.location.x), y: Double(joint.location.y), confidence: Double(joint.confidence)
                )
            }
            people.append(samples)
        }
        let frame = PoseAssembly.frame(
            people: people, time: time, pixelWidth: width, pixelHeight: height, orientation: orientation,
            mirrored: mirrored, dropAtOrBelow: options.dropConfidenceAtOrBelow,
            prominenceConfidence: options.prominenceConfidence
        )
        let candidates = PoseAssembly.candidates(people: people, mirrored: mirrored, dropAtOrBelow: options.dropConfidenceAtOrBelow)
        return PoseEstimate(frame: frame, peopleCount: people.count, visionSeconds: result.seconds, people: candidates)
    }
}
