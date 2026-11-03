import Foundation

/// The whole motion engine as one deterministic value type (brief §6.3):
/// confidence gate → gap hold → One-Euro filter → body frame → view check and side lock → signal
/// source → rep segmenter → per-rep metrics and rules → events.
///
/// Feed frames in capture order with `process`; each call returns the events that frame caused. Call
/// `finish` when the stream ends to flush a rep still waiting for its settle window. Everything is
/// driven by `PoseFrame.t`, so the same frames always produce the same events.
///
/// Frames whose timestamp is not later than the previous one (duplicates, out-of-order) are ignored. A
/// clock that restarts, or one corrupt timestamp far ahead, is survived: after three frames in a row
/// far behind the last one the timeline continues from there (`RepRecord` times stay in capture time).
public struct MotionPipeline: Sendable {
    private struct AuxPoint: Sendable {
        var t = 0.0
        var features = AuxFeatures()
    }

    public let spec: ExerciseSpec
    public let config: MotionConfig

    private var front: FrontEnd
    private var extractor: SignalExtractor
    private var segmenter: RepSegmenter
    private var framingCheck: FramingCheck
    private let rules: RuleEngine
    private var cueScheduler: CueScheduler
    private let auxNeed: AuxFeatures.Need
    private var auxTrace: Ring<AuxPoint>

    private var counted: [RepRecord] = []
    private var partial: [RepRecord] = []
    private var attempts = 0
    private var rejectedCount = 0
    private var clock = FrameClock()
    private var lastTime: Double?
    private var reportedFraming = false
    private var hasBeenReady = false

    /// The latest framing state.
    public private(set) var framing: FramingState = .noPerson
    /// The rep phase while counting; nil while framing is not ready.
    public private(set) var phase: Phase?

    /// Throws `ExerciseSpecError.invalid` if the spec is inconsistent.
    public init(spec: ExerciseSpec, config: MotionConfig = .default) throws {
        try spec.validate()
        self.spec = spec
        self.config = config
        front = FrontEnd(config: config, scoringRoles: spec.requiredJoints)
        extractor = SignalExtractor(signal: spec.signal, calibration: config.calibration)
        segmenter = RepSegmenter(parameters: spec.rep, tuning: config.segmenter)
        framingCheck = FramingCheck(requiredView: spec.view, parameters: config.framing)
        rules = RuleEngine(spec: spec)
        cueScheduler = CueScheduler(minIntervalSeconds: config.cues.minIntervalSeconds)
        auxNeed = AuxFeatures.need(for: spec.metrics)
        let seconds = spec.rep.maxPeriodMs / 1000 + 8
        auxTrace = Ring(capacity: min(16_384, max(512, Int((seconds * 100).rounded(.up)))), fill: AuxPoint())
    }

    /// Results so far.
    public var summary: SetSummary {
        SetSummary(records: counted, partialRecords: partial, isIdle: segmenter.isIdle, rejected: rejectedCount)
    }

    /// The side the lock currently follows.
    public var side: BodySide { front.side }
    /// The view classification of the latest frame.
    public var view: CameraView { front.viewClassifier.view }
    /// The calibrated top and bottom of the signal, in the signal's units.
    public var calibratedRange: (top: Double, bottom: Double) { (segmenter.calibratedTop, segmenter.calibratedBottom) }

    public mutating func process(_ capturedFrame: PoseFrame) -> [MotionEvent] {
        guard let time = clock.accept(capturedFrame.t) else { return [] }
        lastTime = time
        var frame = capturedFrame
        frame.t = time
        var events: [MotionEvent] = []
        events.reserveCapacity(2)

        // Side stays free until counting has started once; from then on, even while counting is paused,
        // it only moves after a second of clear evidence.
        let wasReady = framing.isReady
        front.update(frame, sideFrozen: hasBeenReady)

        let state = framingCheck.update(observation(), at: frame.t)
        if !reportedFraming || state != framing {
            reportedFraming = true
            events.append(.framing(state))
        }
        framing = state
        if state.isReady { hasBeenReady = true }

        let value = extractor.value(front: front, t: frame.t)
        if auxNeed.rawValue != 0 {
            auxTrace.append(AuxPoint(
                t: frame.t, features: AuxFeatures.compute(need: auxNeed, front: front, up: extractor.up)
            ))
        }

        var segmentEvents: [SegmenterEvent] = []
        if state.isReady {
            segmentEvents = segmenter.update(t: frame.t, value: value)
        } else if wasReady {
            segmentEvents = segmenter.pause()
            phase = nil
        }
        absorb(segmentEvents, at: frame.t, into: &events)

        if let value {
            events.append(.signal(segmenter.progress(forValue: value), at: capturedFrame.t))
        }
        return events
    }

    /// Flushes a completed rep that is still inside its settle window. Call when the stream ends.
    public mutating func finish() -> [MotionEvent] {
        var events: [MotionEvent] = []
        absorb(segmenter.finish(), at: lastTime ?? 0, into: &events)
        return events
    }

    // MARK: - Framing

    private func observation() -> FramingObservation {
        var count = 0
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for case let joint? in front.smoother.joints {
            count += 1
            minX = min(minX, joint.x)
            maxX = max(maxX, joint.x)
            minY = min(minY, joint.y)
            maxY = max(maxY, joint.y)
        }

        // Subject size as a fraction of frame height. The bounding box shrinks when the lifter
        // crouches, so it is combined with a posture-invariant estimate: standing height from the
        // torso length (shoulder to hip is about 0.288 of standing height).
        var extent = count > 0 ? max(maxX - minX, maxY - minY) : 0
        if let body = front.body { extent = max(extent, body.torsoLength / config.framing.torsoToHeightRatio) }

        // "Step back" only matters for the joints the exercise needs: a wrist leaving the frame while
        // the lifter squats is no reason to stop counting.
        var required = true
        var touchesEdge = false
        let margin = config.framing.edgeMargin
        let aspect = front.aspect
        for role in spec.requiredJoints {
            guard let joint = front.joint(role) else {
                required = false
                continue
            }
            let nx = joint.x / aspect
            if nx <= margin || nx >= 1 - margin || joint.y <= margin || joint.y >= 1 - margin { touchesEdge = true }
        }
        return FramingObservation(
            confidentJointCount: count, requiredJointsConfident: required, subjectExtent: extent,
            touchesEdge: touchesEdge, view: front.viewClassifier.view
        )
    }

    // MARK: - Segmenter events to app events

    private mutating func absorb(_ segmentEvents: [SegmenterEvent], at t: Double, into events: inout [MotionEvent]) {
        for event in segmentEvents {
            switch event {
            case let .phase(p):
                phase = p
                events.append(.phase(p))
            case let .rep(segment):
                let record = makeRecord(segment, isCounted: true)
                counted.append(record)
                events.append(.repCompleted(record))
                if let cue = cueScheduler.cue(for: record.issues, at: t) { events.append(.cue(cue)) }
            case let .partial(segment):
                let record = makeRecord(segment, isCounted: false)
                partial.append(record)
                events.append(.partialRep(record))
            case .rejected:
                rejectedCount += 1
            case .idle:
                events.append(.idle)
            }
        }
    }

    private mutating func makeRecord(_ segment: RepSegment, isCounted: Bool) -> RepRecord {
        attempts += 1
        // The segmenter names the legs by position (first leg = eccentric). A lift-first exercise works on
        // the first leg, so there the names swap and the velocity is the first leg's.
        let liftFirst = spec.rep.liftFirst
        let timing = LegTiming(
            eccMs: liftFirst ? segment.conMs : segment.eccMs,
            conMs: liftFirst ? segment.eccMs : segment.conMs,
            conVelocity: liftFirst ? segment.leadVelocity : segment.conVelocity
        )
        var metrics: [MetricKey: Double] = [:]
        for key in spec.metrics {
            if let value = measure(key, segment, timing), value.isFinite { metrics[key] = value }
        }
        let verdict = isCounted ? rules.evaluate(metrics) : RuleResult(issues: [], score: 0, isGood: false)
        // Back to capture time (the offset is zero unless the clock was resynchronised).
        let shift = clock.offset
        return RepRecord(
            index: attempts, isCounted: isCounted,
            tStart: segment.tStart - shift, tBottom: segment.tBottom - shift,
            tLift: segment.tLift - shift, tEnd: segment.tEnd - shift,
            eccMs: timing.eccMs, conMs: timing.conMs, rom: segment.rom,
            bottomValue: segment.bottomValue, topValue: segment.topValue, conVelocity: timing.conVelocity,
            metrics: metrics, issues: verdict.issues, score: verdict.score
        )
    }

    private struct LegTiming {
        var eccMs: Double
        var conMs: Double
        var conVelocity: Double
    }

    private func measure(_ key: MetricKey, _ s: RepSegment, _ timing: LegTiming) -> Double? {
        switch key {
        case .bottomValue: return s.bottomValue
        case .topValue: return s.topValue
        case .rom: return s.rom
        case .eccMs: return timing.eccMs
        case .conMs: return timing.conMs
        case .durationMs: return s.durationMs
        case .conVelocity: return timing.conVelocity
        case .maxTorsoLeanDegDescent:
            return auxPercentile(0.9, from: s.tStart, to: s.tBottom) { $0.torsoLean }
        case .minBodyLineDeg:
            return auxPercentile(0.1, from: s.tStart, to: s.tEnd) { $0.bodyLine }
        case .topElbowDeg:
            return auxPercentile(0.75, from: s.tEnd, to: .infinity) { $0.elbow }
        }
    }

    /// A high or low percentile of a feature over the samples in `[from, to]`, nil if there are none.
    /// Percentiles instead of the raw extreme: the maximum of a noisy angle reads two sigma high, which
    /// would hide a real lockout or lean fault sitting near its limit.
    private func auxPercentile(
        _ fraction: Double, from: Double, to: Double, _ feature: (AuxFeatures) -> Double
    ) -> Double? {
        guard auxTrace.total > 0 else { return nil }
        var values: [Double] = []
        for i in auxTrace.firstAbsolute...auxTrace.lastAbsolute {
            let point = auxTrace[absolute: i]
            guard point.t >= from, point.t <= to else { continue }
            let v = feature(point.features)
            if v.isFinite { values.append(v) }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        return values[min(values.count - 1, max(0, Int((fraction * Double(values.count - 1)).rounded())))]
    }
}
