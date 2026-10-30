import Foundation
import MotionCore

/// Keeps following the same person from frame to frame when Vision finds several.
///
/// Picking the most prominent person on every frame alone is not stable: two people at a similar distance
/// swap places whenever their sizes cross, and the skeleton the engine sees jumps from one to the other.
/// The tracker picks by prominence once, then keeps the candidate that is closest to where the followed
/// person was a moment ago (people move a few percent of the frame between frames, and a crouching lifter
/// stays where they are). A candidate only counts as the same person within a fraction of a body height of
/// that place, so somebody standing beside the lifter is not adopted when the lifter is lost for a moment.
/// It lets go of the person only when
///  * they have not been matched for `lostSeconds` (left the frame, or Vision lost them): until then the
///    frame is reported empty rather than handed to a bystander, or
///  * somebody clearly larger (`takeoverRatio`) has stood in the picture for `takeoverSeconds`, which is the
///    case when the first pick was a passer-by and the lifter stepped in front of the camera later.
///
/// Size for the takeover rule is posture-invariant (the larger of the bounding extent and the height
/// estimated from the torso), so a deep squat does not make the lifter look small.
///
/// Pure value type driven by frame time: the same inputs always give the same choices. Use one tracker per
/// camera session and `reset()` it when the scene changes (switching cameras).
public struct PersonTracker: Sendable {
    public struct Parameters: Equatable, Sendable {
        /// Joints below this confidence do not count.
        public var confidence = 0.3
        /// A candidate is the followed person when its centre lies within this fraction of the person's size
        /// (in frame heights) of where the person was, plus `motionAllowance` for every second since.
        public var matchRadius = 0.2
        /// Extra reach per second since the person was last matched, as a fraction of their size: a person
        /// who is lost for a moment can have walked a little.
        public var motionAllowance = 0.15
        /// ... and never less than this many frame heights, so a small distant person still matches.
        public var minimumMatchRadius = 0.1
        /// Another person must be this many times larger than the followed one to take over.
        public var takeoverRatio = 1.6
        /// ... and stay so for this long.
        public var takeoverSeconds = 1.5
        /// The followed person may go unmatched this long before the tracker follows somebody else.
        public var lostSeconds = 0.6

        public init(
            confidence: Double = 0.3, matchRadius: Double = 0.2, motionAllowance: Double = 0.15,
            minimumMatchRadius: Double = 0.1, takeoverRatio: Double = 1.6, takeoverSeconds: Double = 1.5,
            lostSeconds: Double = 0.6
        ) {
            self.confidence = confidence
            self.matchRadius = matchRadius
            self.motionAllowance = motionAllowance
            self.minimumMatchRadius = minimumMatchRadius
            self.takeoverRatio = takeoverRatio
            self.takeoverSeconds = takeoverSeconds
            self.lostSeconds = lostSeconds
        }
    }

    /// What the tracker needs to know about one candidate, in frame-height units.
    struct Features: Equatable {
        var center: Point2
        /// Larger of the width and height of the confident joints.
        var extent: Double
        /// `extent`, or the standing height estimated from the torso if that is larger.
        var size: Double
        var hasConfidentJoints: Bool
    }

    private struct Anchor {
        var center: Point2
        var size: Double
        var time: Double
    }

    private struct Challenger {
        var center: Point2
        var since: Double
    }

    public let parameters: Parameters
    private var anchor: Anchor?
    private var challenger: Challenger?

    public init(parameters: Parameters = Parameters()) {
        self.parameters = parameters
    }

    /// True while a person is being followed.
    public var isFollowing: Bool { anchor != nil }

    /// Forgets the followed person; the next frame picks by prominence again.
    public mutating func reset() {
        anchor = nil
        challenger = nil
    }

    // MARK: - Selection

    /// The joints of the followed person among `people` (one joint dictionary per person, in PoseFrame
    /// space), or nil when nobody is followed in this frame. `time` is the capture time of the frame.
    public mutating func select(
        from people: [[MotionCore.Joint: Keypoint]], imageAspect: Double, time: Double
    ) -> [MotionCore.Joint: Keypoint]? {
        let aspect = imageAspect.isFinite && imageAspect > 0 ? imageAspect : 1
        guard time.isFinite else {
            // Without a time there is nothing to track against; fall back to prominence.
            guard let index = PoseAssembly.mostProminent(people, imageAspect: aspect, confidence: parameters.confidence) else { return nil }
            return people[index]
        }
        if let anchor, time < anchor.time - 1 { reset() }       // the clock restarted

        let features = people.map { Self.features(of: $0, imageAspect: aspect, confidence: parameters.confidence) }

        if let current = anchor {
            if let matched = bestMatch(to: current, among: features, at: time) {
                let f = features[matched]
                let size = f.size > 0 ? 0.7 * current.size + 0.3 * f.size : current.size
                let updated = Anchor(center: f.center, size: size, time: time)
                anchor = updated
                if let taker = challengerToTakeOver(from: updated, matched: matched, among: features, at: time) {
                    anchor = Anchor(center: features[taker].center, size: features[taker].size, time: time)
                    challenger = nil
                    return people[taker]
                }
                return people[matched]
            }
            challenger = nil
            // Not matched: hold the frame empty for a moment instead of handing it to somebody else.
            if time - current.time < parameters.lostSeconds { return nil }
            anchor = nil
        }

        guard let index = PoseAssembly.mostProminent(people, imageAspect: aspect, confidence: parameters.confidence) else {
            return nil
        }
        anchor = Anchor(center: features[index].center, size: features[index].size, time: time)
        return people[index]
    }

    private func bestMatch(to anchor: Anchor, among features: [Features], at time: Double) -> Int? {
        let elapsed = max(0, time - anchor.time)
        let gate = max(parameters.minimumMatchRadius, (parameters.matchRadius + parameters.motionAllowance * elapsed) * anchor.size)
        var best: (index: Int, distance: Double)?
        for (index, f) in features.enumerated() where f.hasConfidentJoints {
            let d = Geometry.distance(f.center, anchor.center)
            guard d <= gate else { continue }
            if let current = best, d >= current.distance - 1e-12 { continue }
            best = (index, d)
        }
        return best?.index
    }

    /// Updates the challenger and returns the index of the person to switch to once they have been clearly
    /// larger for long enough.
    private mutating func challengerToTakeOver(
        from anchor: Anchor, matched: Int, among features: [Features], at time: Double
    ) -> Int? {
        var biggest: (index: Int, size: Double)?
        for (index, f) in features.enumerated() where index != matched && f.hasConfidentJoints {
            guard f.size >= parameters.takeoverRatio * anchor.size else { continue }
            if let current = biggest, f.size <= current.size { continue }
            biggest = (index, f.size)
        }
        guard let biggest else {
            challenger = nil
            return nil
        }
        let f = features[biggest.index]
        let gate = max(parameters.minimumMatchRadius, parameters.matchRadius * f.size)
        if let current = challenger, Geometry.distance(current.center, f.center) <= gate {
            challenger = Challenger(center: f.center, since: current.since)
            return time - current.since >= parameters.takeoverSeconds ? biggest.index : nil
        }
        challenger = Challenger(center: f.center, since: time)
        return nil
    }

    // MARK: - Features

    /// Centre (mean of the confident torso joints, else of all confident joints), extent and size.
    static func features(of joints: [PoseJoint: Keypoint], imageAspect: Double, confidence: Double) -> Features {
        func point(_ joint: PoseJoint) -> Point2? {
            guard let k = joints[joint], k.confidence >= confidence else { return nil }
            return Geometry.isotropic(k, imageAspect: imageAspect)
        }
        func mean(_ points: [Point2]) -> Point2? {
            guard !points.isEmpty else { return nil }
            let sum = points.reduce(Point2(x: 0, y: 0), +)
            return sum * (1 / Double(points.count))
        }

        let confident = joints.values.filter { $0.confidence >= confidence }
        guard !confident.isEmpty else {
            // Nothing trustworthy: centre on whatever there is so the candidate still has a position.
            let all = joints.values.map { Geometry.isotropic($0, imageAspect: imageAspect) }
            return Features(center: mean(all) ?? Point2(x: 0, y: 0), extent: 0, size: 0, hasConfidentJoints: false)
        }
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for k in confident {
            minX = min(minX, k.x)
            maxX = max(maxX, k.x)
            minY = min(minY, k.y)
            maxY = max(maxY, k.y)
        }
        let extent = max((maxX - minX) * imageAspect, maxY - minY)

        let torsoJoints: [PoseJoint] = [.neck, .root, .leftShoulder, .rightShoulder, .leftHip, .rightHip]
        let center = mean(torsoJoints.compactMap(point))
            ?? mean(confident.map { Geometry.isotropic($0, imageAspect: imageAspect) })
            ?? Point2(x: 0, y: 0)

        var size = extent
        let top = point(.neck) ?? mean([PoseJoint.leftShoulder, .rightShoulder].compactMap(point))
        let bottom = point(.root) ?? mean([PoseJoint.leftHip, .rightHip].compactMap(point))
        if let top, let bottom {
            let ratio = MotionConfig.FramingParameters().torsoToHeightRatio
            size = max(size, Geometry.distance(top, bottom) / ratio)
        }
        return Features(center: center, extent: extent, size: size, hasConfidentJoints: true)
    }
}

extension PoseEstimate {
    /// The frame for the person `tracker` follows. Without a followed person in the picture the frame has
    /// no joints, like any frame where nobody was found. `frame` itself holds the most prominent person
    /// of this one image; use this when several people may be in view over time.
    public func frame(following tracker: inout PersonTracker) -> PoseFrame {
        let joints = tracker.select(from: people, imageAspect: frame.imageAspect, time: frame.t)
        return PoseFrame(t: frame.t, joints: joints ?? [:], imageAspect: frame.imageAspect)
    }
}
