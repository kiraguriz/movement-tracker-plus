import Foundation

/// Fixed-capacity ring addressed by absolute append index, so state machines can remember "the sample
/// where X happened" without holding copies. Preallocated; appending never allocates.
struct Ring<Element: Sendable>: Sendable {
    private var storage: [Element]
    private(set) var total = 0
    let capacity: Int

    init(capacity: Int, fill: Element) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: fill, count: self.capacity)
    }

    var count: Int { min(total, capacity) }
    var firstAbsolute: Int { total - count }
    var lastAbsolute: Int { total - 1 }

    mutating func append(_ element: Element) {
        storage[total % capacity] = element
        total += 1
    }

    subscript(absolute index: Int) -> Element { storage[index % capacity] }
}

/// Why a rep-shaped movement was dropped instead of counted.
public enum RejectReason: String, Codable, Sendable {
    case tooFast, tooSlow
}

/// Timing and extremes of one rep, in the signal's own units.
public struct RepSegment: Equatable, Codable, Sendable {
    public var tStart: TimeInterval
    public var tBottom: TimeInterval
    public var tLift: TimeInterval
    public var tEnd: TimeInterval
    public var rom: Double
    public var bottomValue: Double
    public var topValue: Double
    /// Mean concentric velocity in signal units per second (positive).
    public var conVelocity: Double

    public var eccMs: Double { (tBottom - tStart) * 1000 }
    public var conMs: Double { (tEnd - tLift) * 1000 }
    public var durationMs: Double { (tEnd - tStart) * 1000 }
}

public enum SegmenterEvent: Equatable, Sendable {
    case phase(Phase)
    /// A valid rep: reached the bottom, ROM and period in range.
    case rep(RepSegment)
    /// A dip that left the top and came back without a full rep.
    case partial(RepSegment)
    case rejected(RejectReason)
    /// No movement for the spec's idle time.
    case idle
}

/// Adaptive hysteresis rep segmenter on one signal (brief §6.5).
///
/// The signal is mapped to a normalized height `h` (1 at the calibrated top, 0 at the calibrated
/// bottom). The machine walks `top → descending → bottom → ascending → top`:
///
/// * `top → descending` when `h` stays below `topLeave` (0.60) for `dwellMs`;
/// * `descending → bottom` when `h` stays at or below `bottomEnter` (0.30) for `dwellMs`;
/// * `bottom → ascending` when `h` stays above `bottomLeave` (0.40) for `dwellMs`;
/// * `ascending → top` when `h` stays at or above `topEnter` (0.70) for `dwellMs`.
///
/// 70 % and 30 % of the range are the thresholds the rep must pass; the 10 % offsets on the leaving
/// side are the hysteresis that keeps noise at a threshold from chattering. Dwell is measured on frame
/// timestamps (with the crossing interpolated between samples), never on frame counts.
///
/// Top and bottom start at the spec's priors, so rep 1 counts without any learning. Each counted rep
/// then pulls both estimates toward what it actually did (EMA), which follows depth drift from fatigue.
/// Reps that never reach the bottom threshold are partials. A completed rep is held back for
/// `settleSeconds` after it stops rising so lockout can be measured, then reported with timing edges that
/// are found from the rep's own trace (see `measure`): where the signal actually leaves one plateau and
/// arrives at the next, independent of the calibration and of the 70 % / 30 % counting thresholds.
public struct RepSegmenter: Sendable {
    private struct TracePoint: Sendable {
        var t: Double
        var u: Double
    }

    private struct Context: Sendable {
        var topWindowStart: Int
        var descentIndex: Int
        var descentTime: Double
        var bottomFirstIndex: Int
        var bottomLastIndex: Int
    }

    private struct Pending: Sendable {
        var context: Context
        var confirmIndex: Int
        var confirmTime: Double
        /// Highest level seen since the top was confirmed, and when it was last raised.
        var maxU: Double
        var maxTime: Double
    }

    private struct Measurement {
        var segment: RepSegment
        var uLow: Double
        var uHigh0: Double
        var uHigh1: Double
    }

    private let parameters: RepParameters
    private let tuning: MotionConfig.SegmenterTuning
    /// +1 when the signal falls during the eccentric, −1 when it rises. `u = sign × value` always
    /// falls toward the bottom, so the machine is written once.
    private let sign: Double
    private let priorRange: Double

    private var uTop: Double
    private var uBottom: Double
    private var trace: Ring<TracePoint>
    private var lastTime: Double?
    private var lastU = 0.0
    private var candidateA: Double?
    private var candidateB: Double?
    private var context = Context(topWindowStart: 0, descentIndex: 0, descentTime: 0, bottomFirstIndex: -1, bottomLastIndex: -1)
    private var pending: Pending?
    private var anchorU: Double?
    private var anchorTime = 0.0

    /// The current state. Meaningful once `isArmed`; before that the segmenter is waiting to see the
    /// signal at the top.
    public private(set) var phase: Phase = .top
    public private(set) var isArmed = false
    public private(set) var isIdle = false

    public init(parameters: RepParameters, tuning: MotionConfig.SegmenterTuning = .init()) {
        self.parameters = parameters
        self.tuning = tuning
        sign = parameters.polarity == .down ? 1 : -1
        priorRange = abs(parameters.topPrior - parameters.bottomPrior)
        uTop = sign * parameters.topPrior
        uBottom = sign * parameters.bottomPrior
        let seconds = parameters.maxPeriodMs / 1000 + 8
        trace = Ring(capacity: min(16_384, max(512, Int((seconds * 100).rounded(.up)))), fill: TracePoint(t: 0, u: 0))
    }

    /// The calibrated top and bottom in the signal's own units.
    public var calibratedTop: Double { sign * uTop }
    public var calibratedBottom: Double { sign * uBottom }

    /// Gauge position of a raw value: 0 at the calibrated top, 1 at the calibrated bottom.
    public func progress(forValue value: Double) -> Double {
        1 - min(1, max(0, height(sign * value)))
    }

    private func height(_ u: Double) -> Double { (u - uBottom) / (uTop - uBottom) }
    private func level(_ fraction: Double) -> Double { uBottom + fraction * (uTop - uBottom) }
    private var dwellSeconds: Double { parameters.dwellMs / 1000 }

    // MARK: - Updates

    /// Feeds one sample. `value` is nil when the signal is unavailable this frame; time still passes,
    /// so a completed rep can settle, but no transition can progress.
    public mutating func update(t: TimeInterval, value: Double?) -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        guard t.isFinite else { return events }
        if let lastTime, t <= lastTime { return events }
        guard let value, value.isFinite else {
            settlePendingIfDue(at: t, into: &events)
            return events
        }

        let u = sign * value
        trace.append(TracePoint(t: t, u: u))
        let index = trace.lastAbsolute
        if let lastTime, t - lastTime > tuning.maxSampleGapSeconds {
            candidateA = nil
            candidateB = nil
        }
        defer {
            lastTime = t
            lastU = u
        }

        trackIdle(t: t, u: u, into: &events)
        guard isArmed else {
            if height(u) >= tuning.topEnter { arm(at: index, into: &events) }
            return events
        }

        if var p = pending, u > p.maxU + 0.02 * (uTop - uBottom) {
            p.maxU = u
            p.maxTime = t
            pending = p
        }
        settlePendingIfDue(at: t, into: &events)

        switch phase {
        case .top:
            let threshold = level(tuning.topLeave)
            if held(&candidateA, u < threshold, threshold, t, u) {
                finalizePending(into: &events)
                context = Context(topWindowStart: context.topWindowStart, descentIndex: index, descentTime: t, bottomFirstIndex: -1, bottomLastIndex: -1)
                enter(.descending, into: &events)
            }
        case .descending:
            let topLevel = level(tuning.topEnter)
            let bottomLevel = level(tuning.bottomEnter)
            if held(&candidateB, u >= topLevel, topLevel, t, u) {
                finishPartial(endIndex: index, into: &events)
                context.topWindowStart = index
                enter(.top, into: &events)
            } else if held(&candidateA, u <= bottomLevel, bottomLevel, t, u) {
                context.bottomFirstIndex = index
                context.bottomLastIndex = index
                enter(.bottom, into: &events)
            } else {
                abortIfTooSlow(at: t, into: &events)
            }
        case .bottom:
            context.bottomLastIndex = index
            let threshold = level(tuning.bottomLeave)
            if held(&candidateA, u > threshold, threshold, t, u) {
                enter(.ascending, into: &events)
            } else {
                abortIfTooSlow(at: t, into: &events)
            }
        case .ascending:
            let topLevel = level(tuning.topEnter)
            let bottomLevel = level(tuning.bottomEnter)
            if held(&candidateB, u >= topLevel, topLevel, t, u) {
                pending = Pending(context: context, confirmIndex: index, confirmTime: t, maxU: u, maxTime: t)
                context.topWindowStart = index
                enter(.top, into: &events)
            } else if held(&candidateA, u <= bottomLevel, bottomLevel, t, u) {
                context.bottomLastIndex = index
                enter(.bottom, into: &events)
            } else {
                abortIfTooSlow(at: t, into: &events)
            }
        }
        return events
    }

    /// Reports a rep that is still waiting for its settle window. Call when the stream ends.
    public mutating func finish() -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        finalizePending(into: &events)
        return events
    }

    /// Stops counting: reports a rep already completed, drops one in progress without any event, and
    /// waits to see the signal at the top again before resuming. Calibration is kept.
    public mutating func pause() -> [SegmenterEvent] {
        var events: [SegmenterEvent] = []
        finalizePending(into: &events)
        disarm()
        return events
    }

    // MARK: - State helpers

    private mutating func arm(at index: Int, into events: inout [SegmenterEvent]) {
        isArmed = true
        context = Context(topWindowStart: index, descentIndex: index, descentTime: 0, bottomFirstIndex: -1, bottomLastIndex: -1)
        candidateA = nil
        candidateB = nil
        anchorU = nil
        isIdle = false
        enter(.top, into: &events)
    }

    /// Stops counting until the signal is seen at the top again. `keepIdleTracking` is for an abandoned
    /// rep: the lifter is still there, so the idle timer keeps running. A pause means they are gone.
    private mutating func disarm(keepIdleTracking: Bool = false) {
        isArmed = false
        phase = .top
        candidateA = nil
        candidateB = nil
        pending = nil
        lastTime = nil
        if !keepIdleTracking {
            anchorU = nil
            isIdle = false
        }
    }

    private mutating func enter(_ next: Phase, into events: inout [SegmenterEvent]) {
        phase = next
        candidateA = nil
        candidateB = nil
        events.append(.phase(next))
    }

    /// True once `condition` has held for the dwell time. The start is the interpolated threshold
    /// crossing between the previous and the current sample, so dwell does not depend on frame rate.
    private func held(_ start: inout Double?, _ condition: Bool, _ threshold: Double, _ t: Double, _ u: Double) -> Bool {
        guard condition else {
            start = nil
            return false
        }
        if start == nil {
            if let previous = lastTime, t - previous <= tuning.maxSampleGapSeconds, u != lastU {
                let fraction = min(1, max(0, (threshold - lastU) / (u - lastU)))
                start = previous + fraction * (t - previous)
            } else {
                start = t
            }
        }
        return t - (start ?? t) >= dwellSeconds
    }

    private mutating func trackIdle(t: Double, u: Double, into events: inout [SegmenterEvent]) {
        let band = tuning.idleMovementFraction * (uTop - uBottom)
        guard let anchor = anchorU else {
            anchorU = u
            anchorTime = t
            return
        }
        if abs(u - anchor) > band {
            anchorU = u
            anchorTime = t
            isIdle = false
        } else if !isIdle, t - anchorTime >= parameters.idleSeconds {
            isIdle = true
            events.append(.idle)
        }
    }

    private mutating func abortIfTooSlow(at t: Double, into events: inout [SegmenterEvent]) {
        guard t - context.descentTime > parameters.maxPeriodMs / 1000 else { return }
        events.append(.rejected(.tooSlow))
        disarm(keepIdleTracking: true)
    }

    // MARK: - Rep measurement

    /// A completed rep waits until the signal has stopped reaching new highs for `settleSeconds`, so a
    /// slow rise to lockout is measured at its real top; `maxSettleSeconds` bounds the wait.
    private mutating func settlePendingIfDue(at t: Double, into events: inout [SegmenterEvent]) {
        guard let pending else { return }
        if t - pending.maxTime >= tuning.settleSeconds || t - pending.confirmTime >= tuning.maxSettleSeconds {
            finalizePending(into: &events)
        }
    }

    private mutating func finalizePending(into events: inout [SegmenterEvent]) {
        guard let p = pending else { return }
        pending = nil
        // The window ends when the signal settled; later samples may already belong to the next descent.
        var end = trace.lastAbsolute
        let windowEnd = min(p.maxTime + tuning.settleSeconds, p.confirmTime + tuning.maxSettleSeconds)
        while end > p.confirmIndex, trace[absolute: end].t > windowEnd { end -= 1 }
        guard let m = measure(p.context, confirmIndex: p.confirmIndex, end: end) else { return }

        let duration = m.segment.durationMs
        if m.segment.rom < parameters.minRom {
            events.append(.partial(m.segment))
        } else if duration < parameters.minPeriodMs {
            events.append(.rejected(.tooFast))
        } else if duration > parameters.maxPeriodMs {
            events.append(.rejected(.tooSlow))
        } else {
            calibrate(with: m)
            events.append(.rep(m.segment))
        }
    }

    private mutating func finishPartial(endIndex: Int, into events: inout [SegmenterEvent]) {
        guard let m = measure(context, confirmIndex: nil, end: endIndex) else { return }
        // A flick shorter than the shortest rep is noise or a bump, not an attempt.
        if m.segment.durationMs < parameters.minPeriodMs {
            events.append(.rejected(.tooFast))
        } else {
            events.append(.partial(m.segment))
        }
    }

    /// EMA of top and bottom toward what a counted rep did, kept within sane bounds of the priors.
    private mutating func calibrate(with m: Measurement) {
        let alpha = tuning.calibrationAlpha
        uTop += alpha * ((m.uHigh0 + m.uHigh1) / 2 - uTop)
        uBottom += alpha * (m.uLow - uBottom)
        let minRange = max(parameters.minRom, 0.5 * priorRange)
        let maxRange = 2 * priorRange
        let range = uTop - uBottom
        let mid = (uTop + uBottom) / 2
        if range < minRange {
            uTop = mid + minRange / 2
            uBottom = mid - minRange / 2
        } else if range > maxRange {
            uTop = mid + maxRange / 2
            uBottom = mid - maxRange / 2
        }
    }

    /// The value below which `fraction` of the samples in `from...to` fall.
    private func percentile(_ fraction: Double, _ from: Int, _ to: Int) -> Double {
        var values: [Double] = []
        values.reserveCapacity(to - from + 1)
        for i in from...to { values.append(trace[absolute: i].u) }
        values.sort()
        return values[min(values.count - 1, max(0, Int((fraction * Double(values.count - 1)).rounded())))]
    }

    private func lastIndex(from: Int, downTo bound: Int, where match: (Double) -> Bool) -> Int? {
        var i = from
        while i >= bound {
            if match(trace[absolute: i].u) { return i }
            i -= 1
        }
        return nil
    }

    private func firstIndex(from: Int, upTo bound: Int, where match: (Double) -> Bool) -> Int? {
        var i = from
        while i <= bound {
            if match(trace[absolute: i].u) { return i }
            i += 1
        }
        return nil
    }

    /// When a movement from `from` to `to` (in signal units) began and how long it took, from the trace
    /// samples `first...last`.
    ///
    /// Every sample inside the band of the movement (`edgeFraction` to `1 - edgeFraction` of the way) is
    /// turned into the phase `s` of a cosine-eased movement that would be at that height,
    /// `s = acos(1 - 2x) / pi`, and a line `s = (t - t0) / T` is fitted through them. That reads the start
    /// and stop of the movement off its steep middle, where the signal is far above the noise, instead
    /// of timing the first and last few percent, where a smooth movement hardly moves and noise decides.
    /// An eased movement is timed exactly, a jerk-limited one about 15 % short, a squat whose thigh
    /// angle is eased (so the height is flat at the top) about 20 % short.
    private func fitTransition(from: Double, to: Double, first: Int, last: Int) -> (start: Double, duration: Double)? {
        let band = tuning.edgeFraction
        guard last > first, band > 0, band < 0.5, abs(to - from) > 1e-9 else { return nil }
        let span = to - from
        var sumT = 0.0, sumS = 0.0, count = 0
        var samples: [(t: Double, s: Double)] = []
        samples.reserveCapacity(last - first + 1)
        for i in first...last {
            let point = trace[absolute: i]
            let x = (point.u - from) / span
            guard x >= band, x <= 1 - band else { continue }
            let s = acos(1 - 2 * x) / .pi
            samples.append((point.t, s))
            sumT += point.t
            sumS += s
            count += 1
        }
        if count < 3 {
            // Too few samples inside the band (a very fast movement at a low frame rate): use the two
            // interpolated crossings of the band edges instead.
            samples.removeAll()
            for level in [band, 1 - band] {
                var crossingTime: Double?
                for i in first..<last {
                    let a = trace[absolute: i], b = trace[absolute: i + 1]
                    let xa = (a.u - from) / span, xb = (b.u - from) / span
                    if xa < level, xb >= level {
                        crossingTime = a.t + (level - xa) / (xb - xa) * (b.t - a.t)
                        break
                    }
                }
                guard let crossingTime else { return nil }
                samples.append((crossingTime, acos(1 - 2 * level) / .pi))
            }
            sumT = samples.reduce(0) { $0 + $1.t }
            sumS = samples.reduce(0) { $0 + $1.s }
            count = samples.count
        }
        let meanT = sumT / Double(count), meanS = sumS / Double(count)
        var covariance = 0.0, variance = 0.0
        for sample in samples {
            covariance += (sample.t - meanT) * (sample.s - meanS)
            variance += (sample.t - meanT) * (sample.t - meanT)
        }
        guard variance > 1e-12, covariance > 1e-12 else { return nil }
        let duration = variance / covariance
        return (meanT - meanS * duration, duration)
    }

    /// Measures a rep from the sample trace. Plateau levels are percentiles of the samples in each phase
    /// window (the bottom window is the time spent in the bottom phase; the top windows are before the
    /// descent and just after the rise), not the raw minimum and maximum: an extreme of a noisy plateau
    /// sits two sigma off its typical level and would put the timing edges inside the noise.
    ///
    /// The timing edges are where the signal actually leaves the top plateau, arrives at the bottom
    /// plateau, leaves it and arrives back at the top (`fitTransition`), not where it crosses the 70 % and
    /// 30 % counting thresholds. They are the eccentric and concentric times a lifter would quote.
    private func measure(_ ctx: Context, confirmIndex: Int?, end rawEnd: Int) -> Measurement? {
        let first = max(ctx.topWindowStart, trace.firstAbsolute)
        let end = min(rawEnd, trace.lastAbsolute)
        guard first < end else { return nil }

        // Bottom window: the time in the bottom phase, or, for a dip that never got there, the samples
        // around its lowest point.
        var iMin = first
        var uMin = Double.infinity
        for i in first...end where trace[absolute: i].u < uMin {
            uMin = trace[absolute: i].u
            iMin = i
        }
        let bottomStart: Int
        let bottomEnd: Int
        if ctx.bottomFirstIndex >= first {
            bottomStart = min(ctx.bottomFirstIndex, end)
            bottomEnd = min(max(ctx.bottomLastIndex, bottomStart), end)
        } else {
            bottomStart = max(first, iMin - 1)
            bottomEnd = min(end, iMin + 1)
        }
        let uLow = percentile(0.2, bottomStart, bottomEnd)

        let descentEnd = min(max(ctx.descentIndex, first), end)
        let uHigh0 = percentile(0.8, first, descentEnd)
        let riseStart = confirmIndex.map { min(max($0, bottomEnd), end) } ?? max(bottomEnd, end - 4)
        let uHigh1 = percentile(0.8, riseStart, end)

        let span0 = uHigh0 - uLow
        let span1 = uHigh1 - uLow
        guard span0 > 1e-9, span1 > 1e-9 else { return nil }
        let band = tuning.edgeFraction

        func crossing(_ i: Int, _ j: Int, _ levelValue: Double) -> Double {
            let a = trace[absolute: i]
            let b = trace[absolute: j]
            guard b.u != a.u else { return b.t }
            let fraction = min(1, max(0, (levelValue - a.u) / (b.u - a.u)))
            return a.t + fraction * (b.t - a.t)
        }

        // The descent: from the last sample before the bottom window that is still within the band of the
        // top plateau, to the first sample that is within the band of the bottom plateau.
        let descentBandTop = uHigh0 - band * span0
        let descentBandBottom = uLow + band * span0
        let iDescent = lastIndex(from: bottomStart, downTo: first) { $0 >= descentBandTop } ?? first
        let iArrival = firstIndex(from: max(iDescent, first), upTo: bottomEnd) { $0 <= descentBandBottom } ?? bottomEnd
        var tStart: Double
        var tBottom: Double
        if let fit = fitTransition(from: uHigh0, to: uLow, first: iDescent, last: max(iArrival, min(iDescent + 1, end))) {
            tStart = fit.start
            tBottom = fit.start + fit.duration
        } else {
            tStart = iDescent < bottomStart ? crossing(iDescent, iDescent + 1, descentBandTop) : trace[absolute: iDescent].t
            tBottom = iArrival > iDescent ? crossing(iArrival - 1, iArrival, descentBandBottom) : trace[absolute: iArrival].t
        }
        tStart = max(trace[absolute: first].t, tStart)
        tBottom = max(tStart, tBottom)

        // The rise: from the last sample at the bottom plateau before the top was confirmed, to the first
        // sample back at the top plateau. (Searching back from `end` could reach into the next descent.)
        let riseBandBottom = uLow + band * span1
        let riseBandTop = uLow + (1 - band) * span1
        let riseSearchFrom = confirmIndex.map { min($0, end) } ?? end
        let iLift = lastIndex(from: riseSearchFrom, downTo: min(iArrival, riseSearchFrom)) { $0 <= riseBandBottom } ?? min(iArrival, riseSearchFrom)
        let iTop = firstIndex(from: iLift, upTo: end) { $0 >= riseBandTop } ?? end
        var tLift: Double
        var tEnd: Double
        if let fit = fitTransition(from: uLow, to: uHigh1, first: iLift, last: max(iTop, min(iLift + 1, end))) {
            tLift = fit.start
            tEnd = fit.start + fit.duration
        } else {
            tLift = iLift < end ? crossing(iLift, iLift + 1, riseBandBottom) : trace[absolute: iLift].t
            tEnd = iTop > iLift ? crossing(iTop - 1, iTop, riseBandTop) : trace[absolute: iTop].t
        }
        if tLift < tBottom {
            // A reversal with no pause: the two fits overlap by noise, and meet in the middle.
            let middle = max(tStart, (tBottom + tLift) / 2)
            tBottom = middle
            tLift = middle
        }
        tEnd = max(tLift, min(tEnd, trace[absolute: end].t))

        // Mean concentric velocity from the 10 %-to-90 % part of the rise: the steep part, where noise
        // moves the crossing times least.
        let velocityLow = uLow + 0.1 * span1
        let velocityHigh = uLow + 0.9 * span1
        let velocityFrom = max(iLift, iArrival)
        var iV0 = velocityFrom
        while iV0 < end, trace[absolute: iV0].u < velocityLow { iV0 += 1 }
        var iV1 = iV0
        while iV1 < end, trace[absolute: iV1].u < velocityHigh { iV1 += 1 }
        let tV0 = iV0 > velocityFrom ? crossing(iV0 - 1, iV0, velocityLow) : trace[absolute: iV0].t
        let tV1 = iV1 > iV0 ? crossing(iV1 - 1, iV1, velocityHigh) : trace[absolute: iV1].t
        let riseSeconds = max(tV1 - tV0, 1e-3)

        let segment = RepSegment(
            tStart: tStart, tBottom: tBottom, tLift: tLift, tEnd: tEnd,
            rom: min(span0, span1),
            bottomValue: sign * uLow,
            topValue: sign * uHigh1,
            conVelocity: 0.8 * span1 / riseSeconds
        )
        return Measurement(segment: segment, uLow: uLow, uHigh0: uHigh0, uHigh1: uHigh1)
    }
}
