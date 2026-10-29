import Foundation

/// The 19 body joints reported by Vision's 2D human body pose request. Vision has no foot points.
public enum Joint: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case nose, leftEye, rightEye, leftEar, rightEar, neck
    case leftShoulder, rightShoulder, leftElbow, rightElbow, leftWrist, rightWrist
    case root, leftHip, rightHip, leftKnee, rightKnee, leftAnkle, rightAnkle
}

/// One joint position in the upright image the user sees: normalized 0...1, origin bottom-left, y up,
/// mirrored whenever the preview is mirrored. `confidence` is Vision's 0...1 score.
public struct Keypoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var confidence: Double

    public init(x: Double, y: Double, confidence: Double) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

extension Keypoint: Codable {
    // Encoded as [x, y, confidence] to keep pose fixtures small.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
        confidence = try container.decode(Double.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(confidence)
    }
}

/// One frame of pose estimation: the unit that flows from PoseCapture into MotionCore.
public struct PoseFrame: Equatable, Codable, Sendable {
    /// Capture presentation time in seconds on a monotonic clock. Only differences are meaningful.
    public var t: TimeInterval
    /// Joints found in this frame. A missing joint is absent, never zero.
    public var joints: [Joint: Keypoint]
    /// Width divided by height of the upright image. Multiply x by this to get equal units on both axes.
    public var imageAspect: Double

    public init(t: TimeInterval, joints: [Joint: Keypoint], imageAspect: Double) {
        self.t = t
        self.joints = joints
        self.imageAspect = imageAspect
    }
}
