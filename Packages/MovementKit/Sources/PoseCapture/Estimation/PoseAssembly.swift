import CoreGraphics
import Foundation
import ImageIO
import MotionCore
import Vision

/// MotionCore's joint; Vision declares its own `Joint`.
typealias PoseJoint = MotionCore.Joint

/// A joint exactly as Vision reported it: normalized coordinates of the oriented image, origin
/// bottom-left, y up.
struct VisionJointSample: Equatable, Sendable {
    var x: Double
    var y: Double
    var confidence: Double
}

/// The pure part of pose estimation: joint-name mapping, person selection and PoseFrame assembly.
enum PoseAssembly {
    /// Vision joint name to MotionCore joint. The two sets are identical (19 joints).
    static func joint(for name: HumanBodyPoseObservation.JointName) -> PoseJoint? {
        switch name {
        case .nose: .nose
        case .leftEye: .leftEye
        case .rightEye: .rightEye
        case .leftEar: .leftEar
        case .rightEar: .rightEar
        case .neck: .neck
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        case .root: .root
        case .leftHip: .leftHip
        case .rightHip: .rightHip
        case .leftKnee: .leftKnee
        case .rightKnee: .rightKnee
        case .leftAnkle: .leftAnkle
        case .rightAnkle: .rightAnkle
        @unknown default: nil
        }
    }

    /// Pose keypoints of one person: drops joints Vision could not find (confidence at or below
    /// `dropAtOrBelow`, or non-finite values; Vision reports those with confidence 0 and a placeholder
    /// position), applies the mirroring and keeps every other joint with its confidence.
    static func keypoints(
        from samples: [PoseJoint: VisionJointSample], mirrored: Bool, dropAtOrBelow: Double = 0
    ) -> [PoseJoint: Keypoint] {
        var joints: [PoseJoint: Keypoint] = [:]
        joints.reserveCapacity(samples.count)
        for (joint, s) in samples {
            guard s.x.isFinite, s.y.isFinite, s.confidence.isFinite, s.confidence > dropAtOrBelow else { continue }
            let p = PoseGeometry.poseCoordinates(x: s.x, y: s.y, mirrored: mirrored)
            joints[joint] = Keypoint(x: p.x, y: p.y, confidence: min(1, s.confidence))
        }
        return joints
    }

    /// The index of the most prominent person: the one whose confident joints span the largest extent
    /// (the larger of width and height in frame-height units, the same notion MotionCore's framing
    /// uses for "subject size"); ties go to the higher total confidence, then the lower index.
    /// Nil for no candidates.
    static func mostProminent(_ people: [[PoseJoint: Keypoint]], imageAspect: Double, confidence: Double = 0.3) -> Int? {
        var best: (index: Int, extent: Double, total: Double)?
        for (index, joints) in people.enumerated() {
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity
            var total = 0.0
            for keypoint in joints.values {
                total += keypoint.confidence
                guard keypoint.confidence >= confidence else { continue }
                minX = min(minX, keypoint.x)
                maxX = max(maxX, keypoint.x)
                minY = min(minY, keypoint.y)
                maxY = max(maxY, keypoint.y)
            }
            let extent = minX <= maxX ? max((maxX - minX) * imageAspect, maxY - minY) : 0
            if let current = best {
                if extent > current.extent + 1e-9 || (abs(extent - current.extent) <= 1e-9 && total > current.total + 1e-9) {
                    best = (index, extent, total)
                }
            } else {
                best = (index, extent, total)
            }
        }
        return best?.index
    }

    /// Every person with at least one usable joint, as PoseFrame-space keypoints.
    static func candidates(
        people: [[PoseJoint: VisionJointSample]], mirrored: Bool, dropAtOrBelow: Double = 0
    ) -> [[PoseJoint: Keypoint]] {
        people.map { keypoints(from: $0, mirrored: mirrored, dropAtOrBelow: dropAtOrBelow) }.filter { !$0.isEmpty }
    }

    /// Builds the frame for one image from every person Vision found: the most prominent one.
    static func frame(
        people: [[PoseJoint: VisionJointSample]], time: TimeInterval, pixelWidth: Int, pixelHeight: Int,
        orientation: CGImagePropertyOrientation, mirrored: Bool, dropAtOrBelow: Double = 0, prominenceConfidence: Double = 0.3
    ) -> PoseFrame {
        let aspect = PoseGeometry.imageAspect(pixelWidth: pixelWidth, pixelHeight: pixelHeight, orientation: orientation)
        let found = candidates(people: people, mirrored: mirrored, dropAtOrBelow: dropAtOrBelow)
        guard let index = mostProminent(found, imageAspect: aspect, confidence: prominenceConfidence) else {
            return PoseFrame(t: time, joints: [:], imageAspect: aspect)
        }
        return PoseFrame(t: time, joints: found[index], imageAspect: aspect)
    }
}

extension Duration {
    /// The duration in seconds.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
