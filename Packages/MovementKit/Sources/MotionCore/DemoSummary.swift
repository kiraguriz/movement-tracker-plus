import Foundation

/// What a demonstration measured, as plain numbers for Muse to read next to the two skeleton drawings: the
/// joint angles of the two poses, the pace and the depth of the reps. No coordinates over time, no frames.
public struct DemoSummary: Codable, Equatable, Sendable {
    /// Joint angles of one pose in degrees; nil when a joint needed for the angle was not seen. The body side
    /// that was seen more confidently is used.
    public struct Angles: Codable, Equatable, Sendable {
        public var knee: Double?
        public var hip: Double?
        public var elbow: Double?
        public var shoulder: Double?
        /// Torso lean from vertical.
        public var torsoLean: Double?
        /// Shoulder-hip-ankle angle; 180 is a straight line.
        public var bodyLine: Double?
    }

    public var reps: Int
    public var durationSeconds: Double
    public var view: String
    public var startPose: Angles
    public var middlePose: Angles
    public var medianLowerMs: Double
    public var medianRaiseMs: Double
    /// Median range of motion between the two poses; 1 is the whole way.
    public var medianRange: Double

    public init(result: TeachResult, reps repRecords: [RepRecord], confirmedReps: Int) {
        reps = confirmedReps
        let times = result.frames.map(\.t)
        durationSeconds = Self.round((times.max() ?? 0) - (times.min() ?? 0), 1)
        view = result.view.rawValue
        startPose = Self.angles(result.topFrame)
        middlePose = Self.angles(result.bottomFrame)
        medianLowerMs = Self.round(Self.median(repRecords.map(\.eccMs)), 0)
        medianRaiseMs = Self.round(Self.median(repRecords.map(\.conMs)), 0)
        medianRange = Self.round(Self.median(repRecords.map(\.rom)), 2)
    }

    private static func round(_ value: Double, _ decimals: Int) -> Double {
        let factor = pow(10, Double(decimals))
        return (value * factor).rounded() / factor
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    private static func angles(_ frame: PoseFrame) -> Angles {
        func confidence(_ side: BodySide) -> Double {
            [JointRole.shoulder, .elbow, .wrist, .hip, .knee, .ankle].reduce(0) {
                $0 + (frame.joints[$1.joint(on: side)]?.confidence ?? 0)
            }
        }
        let side: BodySide = confidence(.left) >= confidence(.right) ? .left : .right
        func point(_ role: JointRole) -> Point2? {
            frame.joints[role.joint(on: side)].map { Geometry.isotropic($0, imageAspect: frame.imageAspect) }
        }
        func angle(_ a: JointRole, _ vertex: JointRole, _ c: JointRole) -> Double? {
            guard let pa = point(a), let pv = point(vertex), let pc = point(c) else { return nil }
            return Geometry.includedAngle(at: pv, from: pa, to: pc).map { round($0, 0) }
        }
        var lean: Double?
        if let shoulder = point(.shoulder), let hip = point(.hip) {
            lean = Geometry.angleFromVertical(from: hip, to: shoulder).map { round($0, 0) }
        }
        return Angles(
            knee: angle(.hip, .knee, .ankle), hip: angle(.shoulder, .hip, .knee),
            elbow: angle(.shoulder, .elbow, .wrist), shoulder: angle(.hip, .shoulder, .elbow),
            torsoLean: lean, bodyLine: angle(.shoulder, .hip, .ankle)
        )
    }
}
