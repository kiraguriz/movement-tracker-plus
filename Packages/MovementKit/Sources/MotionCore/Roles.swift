import Foundation

/// Which side of the body a joint belongs to.
public enum BodySide: String, CaseIterable, Codable, Sendable {
    case left, right

    public var opposite: BodySide { self == .left ? .right : .left }
}

/// A side-agnostic joint name. Specs talk about roles ("hip", "knee"); the side lock decides whether a
/// role resolves to the left or the right joint for the current frame.
public enum JointRole: String, CaseIterable, Codable, Sendable {
    case shoulder, elbow, wrist, hip, knee, ankle

    public func joint(on side: BodySide) -> Joint {
        switch (self, side) {
        case (.shoulder, .left): .leftShoulder
        case (.shoulder, .right): .rightShoulder
        case (.elbow, .left): .leftElbow
        case (.elbow, .right): .rightElbow
        case (.wrist, .left): .leftWrist
        case (.wrist, .right): .rightWrist
        case (.hip, .left): .leftHip
        case (.hip, .right): .rightHip
        case (.knee, .left): .leftKnee
        case (.knee, .right): .rightKnee
        case (.ankle, .left): .leftAnkle
        case (.ankle, .right): .rightAnkle
        }
    }
}

extension Joint {
    /// Number of Vision joints.
    static let count = 19

    /// All joints in declaration order. `allCases` builds a new array on every call, which is too costly
    /// for a per-frame loop; this is computed once.
    static let ordered: [Joint] = Joint.allCases

    /// Dense index 0..<19 in declaration order, used for array-backed per-joint state.
    var slot: Int {
        switch self {
        case .nose: 0
        case .leftEye: 1
        case .rightEye: 2
        case .leftEar: 3
        case .rightEar: 4
        case .neck: 5
        case .leftShoulder: 6
        case .rightShoulder: 7
        case .leftElbow: 8
        case .rightElbow: 9
        case .leftWrist: 10
        case .rightWrist: 11
        case .root: 12
        case .leftHip: 13
        case .rightHip: 14
        case .leftKnee: 15
        case .rightKnee: 16
        case .leftAnkle: 17
        case .rightAnkle: 18
        }
    }

    /// The side a joint belongs to; nil for midline joints (nose, neck, root).
    public var side: BodySide? {
        switch self {
        case .leftEye, .leftEar, .leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle: .left
        case .rightEye, .rightEar, .rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle: .right
        case .nose, .neck, .root: nil
        }
    }
}
