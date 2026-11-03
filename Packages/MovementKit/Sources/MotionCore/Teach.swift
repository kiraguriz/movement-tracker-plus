import Foundation

// Teach mode, the app-facing half: watch a demonstration, learn the two salient poses, and hand back
// everything the app needs to build and verify a spec (brief §6.4, plan teach-mode §3.2).
//
// `ExemplarTeacher` (Signal.swift) stays as it is. This file adds what a whole flow needs on top of it:
// the frames of the take are kept for the replay verification, a joint that is often out of frame or
// that hardly moves is left out of the pose (a lunge does not need the wrist in view), and the camera
// view the demonstration was filmed from is recorded.

/// The frames of one demonstration and the number of reps the user says it contained.
public struct TeachTake: Sendable, Equatable {
    public var frames: [PoseFrame]
    public var confirmedReps: Int

    public init(frames: [PoseFrame], confirmedReps: Int) {
        self.frames = frames
        self.confirmedReps = confirmedReps
    }
}

/// What a demonstration taught.
public struct TeachResult: Sendable, Equatable {
    /// The two poses, over only the joints that matter for this movement.
    public var poses: ExemplarPoses
    /// Up-and-down cycles the learned poses count in the demonstration itself. The default for the "how
    /// many did you do?" question; the user's answer, not this number, is what the replay must match.
    public var detectedReps: Int
    /// The camera view the demonstration was filmed from, `.any` when it was not clearly one view.
    public var view: ViewRequirement
    /// The real frames nearest the learned top and bottom poses, for drawing them.
    public var topFrame: PoseFrame
    public var bottomFrame: PoseFrame
    /// Every frame of the take (the lead-in included), for the replay.
    public var frames: [PoseFrame]

    public func take(confirming reps: Int) -> TeachTake {
        TeachTake(frames: frames, confirmedReps: reps)
    }

    /// The spec that counts this movement, with the camera view this demonstration used.
    public func spec(id: String, view: ViewRequirement? = nil) -> ExerciseSpec {
        .taught(id: id, poses: poses, view: view ?? self.view)
    }
}

extension ExerciseSpec {
    /// A spec for a taught exercise that asks for the camera view it was taught from. The exemplar poses
    /// are body-frame coordinates, which depend on the angle the camera sees the body from: taught from the
    /// side and counted from the front, they would count wrongly, so the framing check guides the user
    /// back to the same view.
    public static func taught(id: String, poses: ExemplarPoses, view: ViewRequirement) -> ExerciseSpec {
        var spec = taught(id: id, poses: poses)
        spec.view = view
        return spec
    }
}

/// The learning half of `ExemplarTeacher.finish()` on a plain matrix of pose vectors (`dimension` numbers
/// per row), so the same algorithm serves a role set chosen after the fact. `TeachSessionTests` checks
/// that it gives the teacher's answer on the same data.
enum ExemplarLearning {
    struct Fit {
        var top: [Double]
        var bottom: [Double]
        /// The rows nearest the learned poses.
        var topRow: Int
        var bottomRow: Int
        var cycles: Int
    }

    /// Throws `TeachError.tooLittleMotion` when the rows do not hold two clearly different poses reached
    /// by smooth movement. The cycle count may be below `ExemplarTeacher.neededReps`; the caller decides.
    static func fit(_ matrix: [Double], dimension: Int) throws -> Fit {
        let n = dimension > 0 ? matrix.count / dimension : 0
        guard dimension > 0, n >= 20 else { throw TeachError.tooLittleMotion }

        func vector(_ i: Int) -> [Double] { Array(matrix[(i * dimension)..<((i + 1) * dimension)]) }
        func squared(_ a: [Double], _ b: [Double]) -> Double {
            var s = 0.0
            for k in 0..<dimension { s += (a[k] - b[k]) * (a[k] - b[k]) }
            return s
        }

        var centroid = Array(repeating: 0.0, count: dimension)
        for i in 0..<n { for k in 0..<dimension { centroid[k] += matrix[i * dimension + k] / Double(n) } }
        func farthest(from point: [Double]) -> [Double] {
            var best = vector(0)
            var bestD = -1.0
            for i in 0..<n {
                let v = vector(i)
                let d = squared(v, point)
                if d > bestD { bestD = d; best = v }
            }
            return best
        }
        var a = farthest(from: centroid)
        var b = farthest(from: a)
        a = farthest(from: b)
        b = farthest(from: a)
        guard squared(a, b).squareRoot() >= ExemplarTeacher.minSeparation,
              localSpreadRatio(matrix, dimension: dimension) <= ExemplarTeacher.maxLocalSpreadRatio
        else { throw TeachError.tooLittleMotion }

        var start = Array(repeating: 0.0, count: dimension)
        let head = min(5, n)
        for i in 0..<head { for k in 0..<dimension { start[k] += matrix[i * dimension + k] / Double(head) } }
        let topExtreme = squared(start, a) <= squared(start, b) ? a : b
        let bottomExtreme = squared(start, a) <= squared(start, b) ? b : a

        let k = max(3, n / 10)
        func robust(around extreme: [Double]) -> [Double] {
            let nearest = (0..<n).map { (index: $0, d: squared(vector($0), extreme)) }
                .sorted { $0.d < $1.d }
                .prefix(k)
                .map { vector($0.index) }
            return (0..<dimension).map { dim in
                let sorted = nearest.map { $0[dim] }.sorted()
                return sorted[sorted.count / 2]
            }
        }
        let top = robust(around: topExtreme)
        let bottom = robust(around: bottomExtreme)

        var cycles = 0
        var state = 0 // 0 unknown, 1 at top, 2 at bottom after top
        for i in 0..<n {
            guard let s = PoseVector.progress(vector(i), top: top, bottom: bottom) else { continue }
            if s >= 0.7 {
                if state == 2 { cycles += 1 }
                state = 1
            } else if s <= 0.3, state == 1 {
                state = 2
            }
        }

        func nearestRow(to pose: [Double]) -> Int {
            var best = 0
            var bestD = Double.infinity
            for i in 0..<n {
                let d = squared(vector(i), pose)
                if d < bestD { bestD = d; best = i }
            }
            return best
        }
        return Fit(top: top, bottom: bottom, topRow: nearestRow(to: top), bottomRow: nearestRow(to: bottom), cycles: cycles)
    }

    /// Same measure as `ExemplarTeacher.localSpreadRatio()`.
    static func localSpreadRatio(_ matrix: [Double], dimension: Int) -> Double {
        let n = dimension > 0 ? matrix.count / dimension : 0
        let w = 8
        guard dimension > 0, n >= 2 * w else { return 1 }
        func rms(_ range: Range<Int>) -> Double {
            var mean = Array(repeating: 0.0, count: dimension)
            for i in range { for k in 0..<dimension { mean[k] += matrix[i * dimension + k] / Double(range.count) } }
            var sum = 0.0
            for i in range { for k in 0..<dimension { let d = matrix[i * dimension + k] - mean[k]; sum += d * d } }
            return (sum / Double(range.count)).squareRoot()
        }
        let global = rms(0..<n)
        guard global > 1e-9 else { return 1 }
        var locals: [Double] = []
        var i = 0
        while i + w <= n { locals.append(rms(i..<(i + w))); i += w / 2 }
        locals.sort()
        return locals[locals.count / 4] / global
    }
}

/// The synchronous core of `TeachSession`: pose samples at 15 Hz, the frames of the take, and the analysis.
struct TeachAnalyzer: Sendable {
    /// A role must be seen in at least this share of the samples to be part of the learned pose; one that
    /// is often out of frame would stop the counting whenever it is.
    static let minRoleAvailability = 0.9
    /// A role must carry at least this share of the pose movement to be part of the learned pose.
    static let minRoleShare = 0.05
    /// The last moments of a take are the hand reaching for the Done button.
    static let tailSeconds = 0.7
    /// A take longer than this is cut off.
    static let maxSeconds = 60.0
    static let sampleInterval = 1.0 / 15

    private var front: FrontEnd
    private var clock = FrameClock()
    private let moving: [JointRole]
    private var rows: [Double] = []
    private var rowFrames: [PoseFrame] = []
    private var rowViews: [CameraView] = []
    private var rowTimes: [Double] = []
    private var nextSampleTime = -Double.infinity
    private var isAnalyzing: Bool
    private var firstTime: Double?

    private(set) var frames: [PoseFrame] = []

    /// With `analyzesFromStart` false the frames are only kept until `beginAnalysis()`: the countdown, while
    /// the user is still walking back into position, is part of the take but not of what is learned.
    init(config: MotionConfig = .default, analyzesFromStart: Bool = true) {
        moving = ExemplarTeacher.defaultRoles.filter { $0 != .hip }
        front = FrontEnd(config: config, scoringRoles: ExemplarTeacher.defaultRoles)
        isAnalyzing = analyzesFromStart
    }

    var isFull: Bool {
        guard let first = frames.first, let last = frames.last else { return false }
        return last.t - first.t >= Self.maxSeconds
    }

    var sampleCount: Int { rowFrames.count }

    mutating func beginAnalysis() {
        isAnalyzing = true
        nextSampleTime = -Double.infinity
    }

    mutating func process(_ capturedFrame: PoseFrame) {
        guard !isFull, let time = clock.accept(capturedFrame.t) else { return }
        frames.append(capturedFrame)
        var frame = capturedFrame
        frame.t = time
        front.update(frame, sideFrozen: false)
        guard isAnalyzing, frame.t >= nextSampleTime - 1e-9 else { return }
        guard let body = front.body, front.point(.shoulder) != nil else { return }

        var row = Array(repeating: Double.nan, count: moving.count * 2)
        for (i, role) in moving.enumerated() {
            guard let point = front.point(role) else { continue }
            let n = body.normalize(point)
            row[2 * i] = n.x
            row[2 * i + 1] = n.y
        }
        // A running clock rather than "interval since the last sample", so 60 fps gives 15 Hz, not 12.
        let onSchedule = nextSampleTime.isFinite && frame.t - nextSampleTime < Self.sampleInterval
        nextSampleTime = onSchedule ? nextSampleTime + Self.sampleInterval : frame.t + Self.sampleInterval
        rows.append(contentsOf: row)
        rowFrames.append(capturedFrame)
        rowViews.append(front.viewClassifier.view)
        rowTimes.append(capturedFrame.t)
    }

    // MARK: Analysis

    private struct Prepared {
        var roles: [JointRole]
        var matrix: [Double]
        /// For each matrix row, its index among all samples.
        var sourceRows: [Int]
    }

    /// The roles that go into the pose, and the samples in which all of them were seen.
    private func prepare(upTo limit: Int, trimsRoles: Bool) throws -> Prepared {
        let n = limit
        guard n >= 20 else { throw TeachError.tooLittleMotion }
        let width = moving.count * 2
        func value(_ row: Int, _ column: Int) -> Double { rows[row * width + column] }

        var keep = Array(moving.indices)
        if trimsRoles {
            var available = Array(repeating: 0, count: moving.count)
            var sum = Array(repeating: 0.0, count: width)
            var squares = Array(repeating: 0.0, count: width)
            for row in 0..<n {
                for i in moving.indices where !value(row, 2 * i).isNaN {
                    available[i] += 1
                    for c in [2 * i, 2 * i + 1] {
                        sum[c] += value(row, c)
                        squares[c] += value(row, c) * value(row, c)
                    }
                }
            }
            func movement(_ i: Int) -> Double {
                guard available[i] > 0 else { return 0 }
                let count = Double(available[i])
                return [2 * i, 2 * i + 1].reduce(0.0) { total, c in
                    total + max(0, squares[c] / count - (sum[c] / count) * (sum[c] / count))
                }
            }
            let candidates = moving.indices.filter {
                moving[$0] == .shoulder || Double(available[$0]) >= Self.minRoleAvailability * Double(n)
            }
            let total = candidates.reduce(0.0) { $0 + movement($1) }
            keep = candidates.filter { moving[$0] == .shoulder || (total > 0 && movement($0) / total >= Self.minRoleShare) }
        }

        let keptRoles = Set(keep.map { moving[$0] })
        let roles = ExemplarTeacher.defaultRoles.filter { $0 == .hip || keptRoles.contains($0) }
        var matrix: [Double] = []
        var sourceRows: [Int] = []
        for row in 0..<n {
            guard keep.allSatisfy({ !value(row, 2 * $0).isNaN }) else { continue }
            for i in keep {
                matrix.append(value(row, 2 * i))
                matrix.append(value(row, 2 * i + 1))
            }
            sourceRows.append(row)
        }
        return Prepared(roles: roles, matrix: matrix, sourceRows: sourceRows)
    }

    /// Cycles the learned poses count so far, for the live rep dots. Zero until two poses can be told apart.
    func provisionalCycleCount() -> Int {
        guard let prepared = try? prepare(upTo: sampleCount, trimsRoles: true) else { return 0 }
        let dimension = 2 * prepared.roles.filter { $0 != .hip }.count
        return (try? ExemplarLearning.fit(prepared.matrix, dimension: dimension))?.cycles ?? 0
    }

    func finish(trimsRoles: Bool = true) throws -> TeachResult {
        // The hand reaching for the Done button is not part of the demonstration.
        let cutoff = (frames.last?.t ?? 0) - Self.tailSeconds
        var limit = rowTimes.count
        while limit > 0, rowTimes[limit - 1] > cutoff { limit -= 1 }
        let prepared = try prepare(upTo: limit, trimsRoles: trimsRoles)
        let dimension = 2 * prepared.roles.filter { $0 != .hip }.count
        let fit = try ExemplarLearning.fit(prepared.matrix, dimension: dimension)
        guard fit.cycles >= ExemplarTeacher.neededReps else {
            throw TeachError.tooFewReps(found: fit.cycles, needed: ExemplarTeacher.neededReps)
        }

        let used = prepared.sourceRows
        let side = used.filter { rowViews[$0] == .side }.count
        let facing = used.filter { rowViews[$0] == .front }.count
        let decided = side + facing
        var view = ViewRequirement.any
        if Double(decided) >= 0.5 * Double(used.count) {
            if Double(side) >= 0.7 * Double(decided) { view = .side } else if Double(facing) >= 0.7 * Double(decided) { view = .front }
        }

        return TeachResult(
            poses: ExemplarPoses(roles: prepared.roles, top: fit.top, bottom: fit.bottom),
            detectedReps: fit.cycles,
            view: view,
            topFrame: rowFrames[used[fit.topRow]],
            bottomFrame: rowFrames[used[fit.bottomRow]],
            frames: frames.filter { $0.t <= cutoff }
        )
    }
}

/// Watches the camera while the user frames themselves and demonstrates, and learns the movement from the
/// demonstration (plan teach-mode §3.2).
///
/// ```swift
/// let session = TeachSession()
/// // while framing: let state = await session.process(frame)   // .ready lets the user start
/// await session.beginTake()                                    // the countdown starts: frames are kept now
/// // a second before it ends:  await session.beginAnalysis()
/// // every frame while the user demonstrates: await session.process(frame)
/// let dots = await session.provisionalCycleCount()
/// let result = try await session.finish()
/// let spec = result.spec(id: "taught.lunge.a1b2c3")
/// let verdict = try TaughtVerifier.verify(spec: spec, take: result.take(confirming: 3))
/// ```
public actor TeachSession {
    /// Only the shoulder and the hip have to be in view to start: which other joints matter is learned from
    /// the demonstration itself.
    private static let framingSpec = ExerciseSpec(
        id: "teach.framing", view: .any, requiredJoints: [.shoulder, .hip],
        signal: .relativeHeight(of: .shoulder, to: .hip, scale: .torso),
        rep: RepParameters(polarity: .down, topPrior: 1, bottomPrior: 0, minRom: 0.4)
    )

    private let config: MotionConfig
    private var framing: MotionPipeline
    private var analyzer: TeachAnalyzer?

    public init(config: MotionConfig = .default) {
        self.config = config
        // The framing spec is a constant that validates; failing here would be a programming error.
        framing = try! MotionPipeline(spec: Self.framingSpec, config: config)
    }

    /// Feeds one frame. Returns the framing state, `.ready` once the person has been in view long enough to
    /// start. During a take the frame is kept as well.
    @discardableResult
    public func process(_ frame: PoseFrame) -> FramingState {
        _ = framing.process(frame)
        analyzer?.process(frame)
        return framing.framing
    }

    /// Starts keeping frames (the countdown is part of the take: it is what the replay starts from). A take
    /// already in progress is dropped. Learning begins with `beginAnalysis()`, or at once with
    /// `analyzesFromStart`.
    public func beginTake(analyzesFromStart: Bool = false) {
        analyzer = TeachAnalyzer(config: config, analyzesFromStart: analyzesFromStart)
    }

    /// From the next frame on the movement is learned: the user has walked back into position.
    public func beginAnalysis() {
        analyzer?.beginAnalysis()
    }

    /// Drops the take, for a retry.
    public func discardTake() {
        analyzer = nil
    }

    /// Frames kept so far.
    public var frameCount: Int { analyzer?.frames.count ?? 0 }

    /// The take is as long as it may get; the app ends the demonstration.
    public var isFull: Bool { analyzer?.isFull ?? false }

    /// Cycles seen so far, for the dots on screen.
    public func provisionalCycleCount() -> Int {
        analyzer?.provisionalCycleCount() ?? 0
    }

    /// Throws `TeachError`: `.tooLittleMotion` when the body hardly moved or the movement was not smooth,
    /// `.tooFewReps` when fewer than two cycles were seen.
    public func finish() throws -> TeachResult {
        guard let analyzer else { throw TeachError.tooLittleMotion }
        return try analyzer.finish()
    }
}
