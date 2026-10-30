import Foundation
import Testing
@testable import MotionCore

@Suite("One-Euro filter")
struct OneEuroTests {
    private func std(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    @Test("jitter at rest is strongly reduced")
    func restingJitter() {
        var rng = SplitMix64(seed: 3)
        var filter = OneEuroFilter(MotionConfig.default.filter)
        var raw: [Double] = []
        var out: [Double] = []
        for i in 0..<600 {
            let sample = 0.5 + 0.006 * rng.gaussian()
            raw.append(sample)
            out.append(filter.filter(sample, at: Double(i) / 30))
        }
        #expect(std(Array(out.dropFirst(30))) < 0.5 * std(Array(raw.dropFirst(30))))
    }

    @Test("a fast ramp is followed with little lag, a slow drift is smoothed hard")
    func speedAdaptive() {
        func lag(beta: Double) -> Double {
            var filter = OneEuroFilter(minCutoff: 2.0, beta: beta, dCutoff: 1.5)
            var last = 0.0
            // 0.4 units per second, like a squat.
            for i in 0...60 {
                let t = Double(i) / 30
                last = filter.filter(0.4 * t, at: t)
            }
            return 0.4 * 2.0 - last
        }
        #expect(lag(beta: 6) < lag(beta: 0), "a speed-adaptive cutoff lags less")
        #expect(lag(beta: 6) < 0.05)
    }

    @Test("the response is the same at 15, 30 and 60 fps: it uses real elapsed time")
    func rateIndependence() {
        func response(fps: Double) -> Double {
            var filter = OneEuroFilter(MotionConfig.default.filter)
            var out = 0.0
            // A 0.5 Hz sine, amplitude 0.25 units; the last sample is at exactly t = 4 s for every rate.
            let steps = Int(4 * fps)
            for i in 0...steps {
                let t = Double(i) / fps
                out = filter.filter(0.25 * sin(2 * .pi * 0.5 * t), at: t)
            }
            return out
        }
        let slow = response(fps: 15), mid = response(fps: 30), fast = response(fps: 60)
        #expect(abs(slow - fast) < 0.02)
        #expect(abs(mid - fast) < 0.01)
    }

    @Test("jittered timestamps give the same curve as exact ones")
    func irregularTimes() {
        var rng = SplitMix64(seed: 5)
        var exact = OneEuroFilter(MotionConfig.default.filter)
        var jittered = OneEuroFilter(MotionConfig.default.filter)
        var worst = 0.0
        for i in 0..<240 {
            let nominal = Double(i) / 30
            let t = nominal + max(-0.012, min(0.012, 0.008 * rng.gaussian()))
            let a = exact.filter(0.25 * sin(2 * .pi * 0.5 * nominal), at: nominal)
            let b = jittered.filter(0.25 * sin(2 * .pi * 0.5 * t), at: t)
            if i > 10 { worst = max(worst, abs(a - b)) }
        }
        #expect(worst < 0.01)
    }

    @Test("a long gap lets the output catch up fully")
    func longGap() {
        var filter = OneEuroFilter(MotionConfig.default.filter)
        _ = filter.filter(0, at: 0)
        _ = filter.filter(0, at: 0.033)
        let jumped = filter.filter(1, at: 5)
        #expect(jumped > 0.95)
    }

    @Test("duplicate and backwards timestamps leave the state alone")
    func badTimes() {
        var filter = OneEuroFilter(MotionConfig.default.filter)
        let a = filter.filter(1, at: 1.0)
        #expect(a == 1)
        let b = filter.filter(5, at: 1.0)
        let c = filter.filter(5, at: 0.5)
        #expect(b == 1 && c == 1)
        #expect(filter.current == 1)
    }

    @Test("reset restarts from a value")
    func reset() {
        var filter = OneEuroFilter(MotionConfig.default.filter)
        _ = filter.filter(1, at: 0)
        filter.reset(to: 7, at: 1)
        #expect(filter.current == 7)
        #expect(filter.filter(7, at: 1.033) == 7)
    }
}

@Suite("Pose smoother")
struct PoseSmootherTests {
    private func frame(
        _ t: Double, _ joints: [Joint: (Double, Double, Double)], aspect: Double = 1
    ) -> PoseFrame {
        PoseFrame(
            t: t,
            joints: joints.mapValues { Keypoint(x: $0.0, y: $0.1, confidence: $0.2) },
            imageAspect: aspect
        )
    }

    @Test("the confidence gate is exactly 0.3, inclusive")
    func gate() {
        var smoother = PoseSmoother()
        smoother.update(frame(0, [.nose: (0.5, 0.5, 0.3), .neck: (0.5, 0.4, 0.2999)]))
        #expect(smoother[.nose] != nil)
        #expect(smoother[.neck] == nil)
        #expect(abs(smoother.rawConfidence[Joint.neck.slot] - 0.2999) < 1e-12, "raw confidence is still reported")
    }

    @Test("x is converted to isotropic units with the image aspect")
    func aspect() throws {
        var smoother = PoseSmoother()
        smoother.update(frame(0, [.nose: (0.8, 0.5, 0.9)], aspect: 0.5))
        let nose = try #require(smoother[.nose])
        #expect(abs(nose.x - 0.4) < 1e-12)
        #expect(nose.y == 0.5)
    }

    @Test("a dropout up to 150 ms holds the last value; longer means missing")
    func gapHolding() throws {
        var smoother = PoseSmoother()
        var t = 0.0
        for _ in 0..<5 {
            smoother.update(frame(t, [.nose: (0.5, 0.5, 0.9)]))
            t += 1.0 / 30
        }
        let last = try #require(smoother[.nose])
        let lastTime = t - 1.0 / 30

        smoother.update(frame(lastTime + 0.10, [:]))
        let held = try #require(smoother[.nose])
        #expect(held.isHeld && held.x == last.x && held.y == last.y)

        smoother.update(frame(lastTime + 0.15, [:]))
        #expect(smoother[.nose] != nil, "exactly 150 ms is still held")

        smoother.update(frame(lastTime + 0.1501, [:]))
        #expect(smoother[.nose] == nil)
    }

    @Test("a low-confidence frame counts as a gap, not as a position")
    func lowConfidenceGap() throws {
        var smoother = PoseSmoother()
        smoother.update(frame(0, [.nose: (0.5, 0.5, 0.9)]))
        smoother.update(frame(0.033, [.nose: (0.9, 0.9, 0.1)]))
        let held = try #require(smoother[.nose])
        #expect(held.isHeld && abs(held.x - 0.5) < 1e-12)
    }

    @Test("after a long gap the filter restarts from the raw value instead of smoothing across it")
    func reacquire() throws {
        var smoother = PoseSmoother()
        smoother.update(frame(0, [.nose: (0.2, 0.2, 0.9)]))
        smoother.update(frame(0.033, [.nose: (0.2, 0.2, 0.9)]))
        smoother.update(frame(1.0, [:]))
        smoother.update(frame(1.033, [.nose: (0.8, 0.7, 0.9)]))
        let nose = try #require(smoother[.nose])
        #expect(nose.x == 0.8 && nose.y == 0.7 && !nose.isHeld)
    }

    @Test("short gaps keep the filter state, so the joint eases back instead of jumping")
    func shortGapKeepsState() throws {
        var smoother = PoseSmoother()
        for i in 0..<10 { smoother.update(frame(Double(i) / 30, [.nose: (0.2, 0.2, 0.9)])) }
        smoother.update(frame(10.0 / 30 + 0.1, [.nose: (0.8, 0.8, 0.9)]))
        let nose = try #require(smoother[.nose])
        #expect(nose.x > 0.2 && nose.x < 0.8, "smoothed, not teleported: \(nose.x)")
    }

    @Test("non-finite values are ignored")
    func nonFinite() {
        var smoother = PoseSmoother()
        smoother.update(frame(0, [.nose: (.nan, 0.5, 0.9), .neck: (0.5, .infinity, 0.9), .root: (0.5, 0.5, .nan)]))
        #expect(smoother[.nose] == nil && smoother[.neck] == nil && smoother[.root] == nil)
    }
}
