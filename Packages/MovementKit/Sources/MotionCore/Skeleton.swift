import Foundation

/// One line of the skeleton overlay.
public struct Bone: Hashable, Sendable {
    public let from: Joint
    public let to: Joint

    public init(_ from: Joint, _ to: Joint) {
        self.from = from
        self.to = to
    }

    /// The body side the bone belongs to; nil for midline bones (spine, neck-to-nose, shoulder girdle).
    public var side: BodySide? { from.side ?? to.side }
}

/// The skeleton topology of Vision's 19 joints, for overlays and renderers.
public enum Skeleton {
    public static let bones: [Bone] = [
        // Head and neck
        Bone(.neck, .nose),
        Bone(.nose, .leftEye), Bone(.leftEye, .leftEar),
        Bone(.nose, .rightEye), Bone(.rightEye, .rightEar),
        // Arms
        Bone(.neck, .leftShoulder), Bone(.leftShoulder, .leftElbow), Bone(.leftElbow, .leftWrist),
        Bone(.neck, .rightShoulder), Bone(.rightShoulder, .rightElbow), Bone(.rightElbow, .rightWrist),
        // Spine and hips
        Bone(.neck, .root),
        Bone(.root, .leftHip), Bone(.root, .rightHip),
        // Legs
        Bone(.leftHip, .leftKnee), Bone(.leftKnee, .leftAnkle),
        Bone(.rightHip, .rightKnee), Bone(.rightKnee, .rightAnkle),
    ]

    /// The bones of one body side, for drawing the followed side more strongly.
    public static func bones(on side: BodySide) -> [Bone] {
        bones.filter { $0.side == side }
    }
}
