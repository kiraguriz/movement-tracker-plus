import Foundation
@testable import MotionCore

/// A small kinematic stick figure for movements `SyntheticMotion` does not have: a lunge and a bicep curl.
/// Teach mode must not depend on the two built-in exercises, and `SyntheticMotion` belongs to the engine.
///
/// Side view, camera yawed 8 degrees like the engine's own synthetic data. Left joints are the near ones, so
/// the engine follows the left leg and arm; for a lunge the left leg is the front one.
struct TeachFigure {
    enum Movement: Sendable {
        case lunge, curl
    }

    struct Rep: Sendable {
        /// 0 stays at the start pose, 1 goes all the way to the bottom (lunge) or the top of the curl.
        var depth = 1.0
        var down = 1.5
        var up = 1.3
        var pauseBottom = 0.0
        var pauseTop = 0.8
    }

    struct Noise: Sendable {
        var sigma = 0.005
        var wander = 0.003

        static let none = Noise(sigma: 0, wander: 0)
        static let vision = Noise()
        static let louder = Noise(sigma: 0.0075, wander: 0.0045)
    }

    var movement: Movement
    var reps: [Rep]
    var facingRight = true
    var noise = Noise.vision
    var seed: UInt64 = 1
    var leadIn = 2.0
    var trailing = 1.2
    var fps = 30.0
    var startTime = 1000.0
    /// Joints that are never reported, as when they are out of the picture.
    var hidden: Set<Joint> = []
    /// Scales every duration (0.8 is a brisker pace).
    var tempo = 1.0

    static func reps(_ count: Int, depth: Double = 1, down: Double = 1.5, up: Double = 1.3) -> [Rep] {
        Array(repeating: Rep(depth: depth, down: down, up: up), count: count)
    }

    // MARK: Timeline

    private struct Piece {
        var start: Double
        var end: Double
        var from: Double
        var to: Double
    }

    private func timeline() -> (pieces: [Piece], total: Double) {
        var pieces: [Piece] = []
        var cursor = 0.0
        var current = 0.0
        func add(_ seconds: Double, to target: Double) {
            let d = seconds * tempo
            guard d > 0 else { return }
            pieces.append(Piece(start: cursor, end: cursor + d, from: current, to: target))
            cursor += d
            current = target
        }
        add(leadIn / tempo, to: 0)
        for rep in reps {
            add(rep.down, to: rep.depth)
            add(rep.pauseBottom, to: rep.depth)
            add(rep.up, to: 0)
            add(rep.pauseTop, to: 0)
        }
        add(trailing / tempo, to: 0)
        return (pieces, cursor)
    }

    // MARK: Kinematics

    private static let thigh = 0.44
    private static let shin = 0.43
    private static let torso = 0.50
    private static let upperArm = 0.30
    private static let forearm = 0.27
    private static let ankleHeight = 0.08

    private typealias P = (x: Double, y: Double)

    /// The knee of a two-link leg: `preferForward` takes the intersection in front of the hip-ankle line.
    private static func knee(hip: P, ankle: P) -> P {
        let dx = ankle.x - hip.x
        let dy = ankle.y - hip.y
        let d = min(max((dx * dx + dy * dy).squareRoot(), 1e-9), thigh + shin - 1e-6)
        let a = (thigh * thigh - shin * shin + d * d) / (2 * d)
        let h = max(0, thigh * thigh - a * a).squareRoot()
        let ux = dx / d, uy = dy / d
        let mx = hip.x + a * ux, my = hip.y + a * uy
        let p1 = (x: mx - h * uy, y: my + h * ux)
        let p2 = (x: mx + h * uy, y: my - h * ux)
        return p1.x >= p2.x ? p1 : p2
    }

    private static func lateral(_ joint: Joint) -> Double {
        switch joint {
        case .leftShoulder, .rightShoulder: 0.19
        case .leftElbow, .rightElbow: 0.21
        case .leftWrist, .rightWrist: 0.12
        case .leftHip, .rightHip: 0.11
        case .leftKnee, .rightKnee, .leftAnkle, .rightAnkle: 0.10
        case .leftEye, .rightEye: 0.03
        case .leftEar, .rightEar: 0.075
        case .nose, .neck, .root: 0
        }
    }

    /// The mid-plane position of every joint at movement progress `s` (0 start, 1 end).
    private func joints(at s: Double) -> [Joint: P] {
        var out: [Joint: P] = [:]
        let shoulder: P
        let hip: P
        switch movement {
        case .lunge:
            // The front foot is planted ahead of the hips, the back foot behind them; the pelvis sinks.
            let hipHeight = Self.ankleHeight + 0.75 - 0.42 * s
            hip = (0, hipHeight)
            let front = Self.knee(hip: hip, ankle: (0.45, Self.ankleHeight))
            let back = Self.knee(hip: hip, ankle: (-0.45, Self.ankleHeight))
            out[.leftKnee] = front; out[.leftAnkle] = (0.45, Self.ankleHeight)
            out[.rightKnee] = back; out[.rightAnkle] = (-0.45, Self.ankleHeight)
            shoulder = (hip.x, hip.y + Self.torso)
        case .curl:
            hip = (0, 0.94)
            out[.leftKnee] = (0, 0.51); out[.leftAnkle] = (0, Self.ankleHeight)
            out[.rightKnee] = (0, 0.51); out[.rightAnkle] = (0, Self.ankleHeight)
            shoulder = (0, hip.y + Self.torso)
        }
        out[.leftHip] = hip; out[.rightHip] = hip; out[.root] = hip
        out[.leftShoulder] = shoulder; out[.rightShoulder] = shoulder
        out[.neck] = (shoulder.x, shoulder.y + 0.06)
        out[.nose] = (shoulder.x + 0.07, shoulder.y + 0.24)
        out[.leftEye] = (shoulder.x + 0.04, shoulder.y + 0.28); out[.rightEye] = out[.leftEye]
        out[.leftEar] = (shoulder.x - 0.04, shoulder.y + 0.24); out[.rightEar] = out[.leftEar]
        let elbow: P = (shoulder.x + 0.03, shoulder.y - Self.upperArm)
        out[.leftElbow] = elbow; out[.rightElbow] = elbow
        let wrist: P
        if movement == .curl {
            let theta = s * 140 * Double.pi / 180
            wrist = (elbow.x + Self.forearm * sin(theta), elbow.y - Self.forearm * cos(theta))
        } else {
            wrist = (elbow.x + 0.05, elbow.y - Self.forearm)
        }
        out[.leftWrist] = wrist; out[.rightWrist] = wrist
        return out
    }

    // MARK: Frames

    func frames() -> [PoseFrame] {
        let (pieces, total) = timeline()
        guard !pieces.isEmpty else { return [] }
        var timeRNG = SplitMix64(seed: seed &* 0x9E37_79B9 &+ 1)
        var noiseRNG = SplitMix64(seed: seed &* 0x85EB_CA6B &+ 2)
        let yaw = (facingRight ? 8.0 : 172.0) * Double.pi / 180
        let aspect = 9.0 / 16
        let frameHeight = 2.6
        let centreY = 0.9
        let interval = 1 / fps

        var wanderX = [Double](repeating: 0, count: Joint.count)
        var wanderY = [Double](repeating: 0, count: Joint.count)
        var out: [PoseFrame] = []
        var pieceIndex = 0
        var k = 0
        var previous = 0.0
        var lastTime = -Double.infinity
        while Double(k) * interval <= total {
            let nominal = Double(k) * interval
            k += 1
            let jitter = max(-0.4, min(0.4, timeRNG.gaussian() * 0.1)) * interval
            let tau = max(nominal + jitter, lastTime + 0.2 * interval, 0)
            lastTime = tau

            while pieceIndex < pieces.count - 1, tau > pieces[pieceIndex].end { pieceIndex += 1 }
            let piece = pieces[pieceIndex]
            let u = piece.end > piece.start ? min(1, max(0, (tau - piece.start) / (piece.end - piece.start))) : 1
            let s = piece.from + (piece.to - piece.from) * (0.5 - 0.5 * cos(.pi * u))
            let world = joints(at: s)

            let dt = tau - previous
            previous = tau
            let decay = noise.wander > 0 ? exp(-max(dt, 0) / 0.5) : 0
            let drive = max(0, 1 - decay * decay).squareRoot()
            let nearness = max(-1, min(1, cos(yaw) / 0.5))

            var reported: [Joint: Keypoint] = [:]
            for joint in Joint.allCases {
                guard let p = world[joint], !hidden.contains(joint) else { continue }
                let z: Double = switch joint.side {
                case .left: Self.lateral(joint)
                case .right: -Self.lateral(joint)
                case nil: 0
                }
                let projected = p.x * cos(yaw) + z * sin(yaw)
                var nx = 0.5 + projected / (frameHeight * aspect)
                var ny = 0.5 + (p.y - centreY) / frameHeight
                let bias: Double = switch joint.side {
                case .left: 0.5 * (1 + nearness)
                case .right: 0.5 * (1 - nearness)
                case nil: 1
                }
                var confidence = joint.side == nil ? 0.9 : 0.55 + 0.37 * bias
                confidence += 0.03 * noiseRNG.gaussian()
                let scale = 1 + (1 - bias) * 0.5
                if noise.sigma > 0 {
                    nx += noise.sigma * scale * noiseRNG.gaussian() / aspect
                    ny += noise.sigma * scale * noiseRNG.gaussian()
                }
                if noise.wander > 0 {
                    let slot = joint.slot
                    wanderX[slot] = decay * wanderX[slot] + drive * noise.wander * noiseRNG.gaussian()
                    wanderY[slot] = decay * wanderY[slot] + drive * noise.wander * noiseRNG.gaussian()
                    nx += wanderX[slot] / aspect
                    ny += wanderY[slot]
                }
                guard nx >= 0, nx <= 1, ny >= 0, ny <= 1 else { continue }
                reported[joint] = Keypoint(x: nx, y: ny, confidence: max(0.05, min(1, confidence)))
            }
            out.append(PoseFrame(t: startTime + tau, joints: reported, imageAspect: aspect))
        }
        return out
    }
}

/// Runs a demonstration through `TeachAnalyzer` (the synchronous core of `TeachSession`).
func teachResult(_ frames: [PoseFrame], trimsRoles: Bool = true) throws -> TeachResult {
    var analyzer = TeachAnalyzer()
    for frame in frames { analyzer.process(frame) }
    return try analyzer.finish(trimsRoles: trimsRoles)
}
