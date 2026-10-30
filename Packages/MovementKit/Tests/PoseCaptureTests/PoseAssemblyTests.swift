import CoreGraphics
import Foundation
import ImageIO
import MotionCore
import Testing
import Vision
@testable import PoseCapture

@Suite("Pose assembly")
struct PoseAssemblyTests {
    private func sample(_ x: Double, _ y: Double, _ c: Double = 0.9) -> VisionJointSample {
        VisionJointSample(x: x, y: y, confidence: c)
    }

    @Test func everyVisionJointMapsToOneMotionCoreJoint() {
        let names: [HumanBodyPoseObservation.JointName] = [
            .nose, .leftEye, .rightEye, .leftEar, .rightEar, .neck, .leftShoulder, .rightShoulder, .leftElbow,
            .rightElbow, .leftWrist, .rightWrist, .root, .leftHip, .rightHip, .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
        ]
        let mapped = names.compactMap { PoseAssembly.joint(for: $0) }
        #expect(mapped.count == 19)
        #expect(Set(mapped) == Set(PoseJoint.allCases))
        // Left stays left.
        #expect(PoseAssembly.joint(for: .leftKnee) == .leftKnee)
        #expect(PoseAssembly.joint(for: .rightWrist) == .rightWrist)
    }

    @Test func zeroConfidenceJointsAreDropped() {
        let joints = PoseAssembly.keypoints(
            from: [.nose: sample(0.5, 0.9), .leftWrist: sample(0, 0, 0), .rightWrist: sample(.nan, 0.5)],
            mirrored: false
        )
        #expect(joints.keys.sorted { $0.rawValue < $1.rawValue } == [.nose])
    }

    @Test func dropThresholdIsConfigurable() {
        let samples: [PoseJoint: VisionJointSample] = [.nose: sample(0.5, 0.9, 0.2), .root: sample(0.5, 0.5, 0.6)]
        #expect(PoseAssembly.keypoints(from: samples, mirrored: false, dropAtOrBelow: 0.3).count == 1)
        #expect(PoseAssembly.keypoints(from: samples, mirrored: false).count == 2)
    }

    @Test func confidenceIsCappedAtOne() {
        let joints = PoseAssembly.keypoints(from: [.nose: sample(0.5, 0.5, 1.2)], mirrored: false)
        #expect(joints[.nose]?.confidence == 1)
    }

    @Test func mostProminentPersonHasTheLargestExtent() {
        let small: [PoseJoint: Keypoint] = [
            .nose: Keypoint(x: 0.2, y: 0.5, confidence: 0.9), .root: Keypoint(x: 0.2, y: 0.4, confidence: 0.9),
        ]
        let big: [PoseJoint: Keypoint] = [
            .nose: Keypoint(x: 0.6, y: 0.9, confidence: 0.8), .leftAnkle: Keypoint(x: 0.6, y: 0.1, confidence: 0.8),
        ]
        #expect(PoseAssembly.mostProminent([small, big], imageAspect: 0.5625) == 1)
        #expect(PoseAssembly.mostProminent([big, small], imageAspect: 0.5625) == 0)
        #expect(PoseAssembly.mostProminent([], imageAspect: 1) == nil)
    }

    @Test func prominenceUsesEqualUnitsOnBothAxes() {
        // 0.6 of the width of a 16:9 image is wider than 0.8 of its height.
        let wide: [PoseJoint: Keypoint] = [
            .leftWrist: Keypoint(x: 0.1, y: 0.5, confidence: 0.9), .rightWrist: Keypoint(x: 0.7, y: 0.5, confidence: 0.9),
        ]
        let tall: [PoseJoint: Keypoint] = [
            .nose: Keypoint(x: 0.8, y: 0.1, confidence: 0.9), .leftAnkle: Keypoint(x: 0.8, y: 0.9, confidence: 0.9),
        ]
        #expect(PoseAssembly.mostProminent([tall, wide], imageAspect: 16.0 / 9) == 1)
        #expect(PoseAssembly.mostProminent([tall, wide], imageAspect: 9.0 / 16) == 0)
    }

    @Test func tiesGoToTheHigherTotalConfidenceThenTheLowerIndex() {
        let a: [PoseJoint: Keypoint] = [.nose: Keypoint(x: 0.2, y: 0.8, confidence: 0.5), .root: Keypoint(x: 0.2, y: 0.4, confidence: 0.5)]
        let b: [PoseJoint: Keypoint] = [.nose: Keypoint(x: 0.7, y: 0.8, confidence: 0.9), .root: Keypoint(x: 0.7, y: 0.4, confidence: 0.9)]
        #expect(PoseAssembly.mostProminent([a, b], imageAspect: 1) == 1)
        #expect(PoseAssembly.mostProminent([a, a], imageAspect: 1) == 0)
    }

    @Test func nobodyGivesAnEmptyFrameWithTheRightAspect() {
        let frame = PoseAssembly.frame(
            people: [], time: 3, pixelWidth: 1280, pixelHeight: 720, orientation: .right, mirrored: true
        )
        #expect(frame.joints.isEmpty)
        #expect(frame.t == 3)
        #expect(abs(frame.imageAspect - 720.0 / 1280.0) < 1e-12)
        // A person with only unusable joints counts as nobody too.
        let ghost = PoseAssembly.frame(
            people: [[.nose: sample(0, 0, 0)]], time: 4, pixelWidth: 1280, pixelHeight: 720, orientation: .up, mirrored: false
        )
        #expect(ghost.joints.isEmpty)
    }

    @Test func theMostProminentOfSeveralPeopleIsKept() {
        let far = [PoseJoint.nose: sample(0.3, 0.55), .root: sample(0.3, 0.45)]
        let near = [PoseJoint.nose: sample(0.7, 0.95), .root: sample(0.7, 0.5), .leftAnkle: sample(0.7, 0.05)]
        let frame = PoseAssembly.frame(
            people: [far, near], time: 0, pixelWidth: 720, pixelHeight: 1280, orientation: .up, mirrored: false
        )
        #expect(frame.joints.count == 3)
        #expect(frame.joints[.leftAnkle] != nil)
    }
}

@Suite("Latency statistics")
struct LatencyStatsTests {
    @Test func emptySummary() {
        #expect(LatencySummary(samples: []) == .empty)
        #expect(LatencySummary.percentile(sorted: [], 0.5) == 0)
    }

    @Test func percentilesInterpolate() {
        let s = LatencySummary(samples: [0.010, 0.020, 0.030, 0.040, 0.100])
        #expect(s.count == 5)
        #expect(abs(s.p50 - 0.030) < 1e-12)
        #expect(abs(s.p95 - (0.040 + 0.8 * 0.060)) < 1e-12)   // 0.95 * 4 = 3.8 -> between 0.040 and 0.100
        #expect(abs(s.mean - 0.040) < 1e-12)
        #expect(s.max == 0.100)
    }

    @Test func inputOrderDoesNotMatter() {
        #expect(LatencySummary(samples: [0.3, 0.1, 0.2]) == LatencySummary(samples: [0.1, 0.2, 0.3]))
    }

    @Test func singleSample() {
        let s = LatencySummary(samples: [0.016])
        #expect(s.p50 == 0.016 && s.p95 == 0.016 && s.max == 0.016)
    }

    @Test func windowKeepsTheLatestSamples() {
        var window = LatencyWindow(capacity: 3)
        for value in [0.9, 0.1, 0.2, 0.3] { window.record(value) }
        #expect(window.count == 3)
        #expect(abs(window.summary.p50 - 0.2) < 1e-12)
        #expect(window.summary.max == 0.3)
    }
}
