import Foundation

/// How the body is oriented toward the camera.
public enum CameraView: String, Codable, Sendable {
    case unknown, side, front
}

/// Body-centred coordinates: origin at the hip centre, one unit is one torso length. Scale-free, so
/// the same pose gives the same numbers at any camera distance.
public struct BodyFrame: Equatable, Sendable {
    /// Hip centre in isotropic image units.
    public var origin: Point2
    /// Shoulder-to-hip distance in isotropic image units.
    public var torsoLength: Double
    /// The side the lock currently follows.
    public var side: BodySide
    public var view: CameraView

    /// Maps an isotropic image point into body coordinates (x forward-or-back, y up, in torso lengths).
    public func normalize(_ p: Point2) -> Point2 {
        Point2(x: (p.x - origin.x) / torsoLength, y: (p.y - origin.y) / torsoLength)
    }
}

/// Side-versus-front classifier from shoulder separation divided by torso length, with hysteresis.
///
/// A side view puts the shoulders almost on top of each other (ratio near 0); a front view spreads
/// them by roughly the torso length. The ratio is smoothed with a time constant, and the decision only
/// flips when the ratio crosses the far threshold, so a squat's small wobble cannot flicker the view.
///
/// The first decision uses the same two thresholds: a ratio between them (a three-quarter view) stays
/// `unknown`, which no exercise rejects. Splitting the band at its midpoint instead would let the noise
/// of the very first frame decide, and a wrong "front" is sticky because leaving it needs the far
/// threshold: the same pose at 30 degrees of yaw counted reps in four runs out of five and asked the
/// user to turn sideways in the fifth. A clearly side or clearly front ratio still decides at once;
/// anything nearer the band waits for the smoothed value.
public struct ViewClassifier: Sendable {
    public private(set) var view: CameraView = .unknown
    /// Smoothed shoulder separation / torso length, nil before the first measurement.
    public private(set) var ratio: Double?

    private let parameters: MotionConfig.ViewParameters
    private var lastTime: Double?
    private var firstTime: Double?

    public init(parameters: MotionConfig.ViewParameters = .init()) {
        self.parameters = parameters
    }

    /// Feeds one measurement. `measurement` is nil when the ratio cannot be computed this frame; the
    /// previous decision is kept.
    public mutating func update(ratio measurement: Double?, at t: Double) {
        defer { lastTime = t }
        guard let measurement, measurement.isFinite else { return }
        if let previous = ratio, let lastTime, t > lastTime {
            let alpha = 1 - exp(-(t - lastTime) / max(parameters.smoothingSeconds, 1e-3))
            ratio = previous + alpha * (measurement - previous)
        } else if ratio == nil {
            ratio = measurement
        }
        guard let r = ratio else { return }
        if firstTime == nil { firstTime = t }
        switch view {
        case .unknown:
            // The smoothed ratio starts from the first raw measurement; unless it is clearly one view, let
            // it settle first, so one noisy frame cannot make a decision that is hard to undo.
            let settled = t - (firstTime ?? t) >= 2 * parameters.smoothingSeconds
            if r < parameters.sideBelow, settled || r < parameters.sideBelow - parameters.clearMargin {
                view = .side
            } else if r > parameters.frontAbove, settled || r > parameters.frontAbove + parameters.clearMargin {
                view = .front
            }
        case .side:
            if r > parameters.frontAbove { view = .front }
        case .front:
            if r < parameters.sideBelow { view = .side }
        }
    }

    public mutating func reset() {
        view = .unknown
        ratio = nil
        lastTime = nil
        firstTime = nil
    }
}

/// Picks which body side the engine follows.
///
/// While framing (`frozen == false`) the lock simply follows the more confident side. Once counting
/// starts the lock is frozen: the other side must lead by `margin` continuously for `switchSeconds`
/// of frame time before it takes over. A single noisy frame, or a brief occlusion, never moves it.
public struct SideLock: Sendable {
    public private(set) var side: BodySide?
    public private(set) var leftScore = 0.0
    public private(set) var rightScore = 0.0

    private let parameters: MotionConfig.SideLockParameters
    private var challengerSince: Double?
    private var lastTime: Double?

    public init(parameters: MotionConfig.SideLockParameters = .init()) {
        self.parameters = parameters
    }

    public mutating func update(left: Double, right: Double, at t: Double, frozen: Bool) {
        if let lastTime, t > lastTime {
            let alpha = 1 - exp(-(t - lastTime) / max(parameters.scoreSeconds, 1e-3))
            leftScore += alpha * (left - leftScore)
            rightScore += alpha * (right - rightScore)
        } else if lastTime == nil {
            leftScore = left
            rightScore = right
        }
        lastTime = t

        let better: BodySide = rightScore > leftScore ? .right : .left
        guard let current = side else {
            side = better
            return
        }
        let lead = score(of: current.opposite) - score(of: current)
        if !frozen {
            challengerSince = nil
            if lead > parameters.freeMargin { side = current.opposite }
            return
        }
        if lead >= parameters.margin {
            let since = challengerSince ?? t
            challengerSince = since
            if t - since >= parameters.switchSeconds {
                side = current.opposite
                challengerSince = nil
            }
        } else {
            challengerSince = nil
        }
    }

    private func score(of side: BodySide) -> Double { side == .left ? leftScore : rightScore }
}

/// The per-frame preprocessing stack shared by the pipeline and the teach mode: confidence gate, gap
/// hold, One-Euro filter, side lock, view classification, body frame.
struct FrontEnd: Sendable {
    private(set) var smoother: PoseSmoother
    private(set) var viewClassifier: ViewClassifier
    private(set) var sideLock: SideLock
    private(set) var body: BodyFrame?
    private(set) var aspect = 1.0
    private(set) var time = -Double.infinity

    private let scoringRoles: [JointRole]

    init(config: MotionConfig, scoringRoles: [JointRole]) {
        smoother = PoseSmoother(config: config)
        viewClassifier = ViewClassifier(parameters: config.view)
        sideLock = SideLock(parameters: config.sideLock)
        self.scoringRoles = scoringRoles
    }

    /// The side being followed (left until the first frame decides).
    var side: BodySide { sideLock.side ?? .left }

    mutating func update(_ frame: PoseFrame, sideFrozen: Bool) {
        smoother.update(frame)
        aspect = frame.imageAspect.isFinite && frame.imageAspect > 0 ? frame.imageAspect : 1
        time = frame.t

        sideLock.update(
            left: sideScore(.left), right: sideScore(.right), at: frame.t, frozen: sideFrozen
        )
        let side = self.side

        // Hip centre: both hips, else the followed side's hip, else the other, else Vision's root.
        let leftHip = smoother[.leftHip]?.point
        let rightHip = smoother[.rightHip]?.point
        let hipCentre: Point2? = {
            if let l = leftHip, let r = rightHip { return (l + r) * 0.5 }
            return (side == .left ? leftHip ?? rightHip : rightHip ?? leftHip) ?? smoother[.root]?.point
        }()

        let leftShoulder = smoother[.leftShoulder]?.point
        let rightShoulder = smoother[.rightShoulder]?.point
        let torso: Double? = {
            func length(_ s: BodySide) -> Double? {
                guard let sh = smoother[JointRole.shoulder.joint(on: s)]?.point,
                      let hip = smoother[JointRole.hip.joint(on: s)]?.point else { return nil }
                let d = Geometry.distance(sh, hip)
                return d > 1e-6 ? d : nil
            }
            if let own = length(side) { return own }
            if let other = length(side.opposite) { return other }
            if let l = leftShoulder, let r = rightShoulder, let h = hipCentre {
                let d = Geometry.distance((l + r) * 0.5, h)
                return d > 1e-6 ? d : nil
            }
            return nil
        }()

        // Shoulder separation / torso length. A single visible shoulder is how a side view looks.
        var ratio: Double?
        if let torso {
            if let l = leftShoulder, let r = rightShoulder {
                ratio = abs(l.x - r.x) / torso
            } else if leftShoulder != nil || rightShoulder != nil {
                ratio = 0
            }
        }
        viewClassifier.update(ratio: ratio, at: frame.t)

        if let hipCentre, let torso {
            body = BodyFrame(origin: hipCentre, torsoLength: torso, side: side, view: viewClassifier.view)
        } else {
            body = nil
        }
    }

    /// The smoothed joint for a role on the followed side.
    func joint(_ role: JointRole) -> SmoothedJoint? {
        smoother[role.joint(on: side)]
    }

    func point(_ role: JointRole) -> Point2? { joint(role)?.point }

    private func sideScore(_ side: BodySide) -> Double {
        guard !scoringRoles.isEmpty else { return 0 }
        var sum = 0.0
        for role in scoringRoles { sum += smoother.rawConfidence[role.joint(on: side).slot] }
        return sum / Double(scoringRoles.count)
    }
}
