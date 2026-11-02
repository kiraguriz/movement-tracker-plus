import MotionCore
import SwiftUI

struct LiveTraceSample: Identifiable, Sendable {
    let id: Int
    let depth: Double
    let time: TimeInterval
}

struct LiveTraceMarker: Sendable {
    enum Kind: Sendable { case good, fix, major, partial }
    let sampleID: Int
    let number: Int?
    let kind: Kind

    var status: TraceRepStatus {
        switch kind {
        case .good: .good
        case .fix: .fix
        case .major: .major
        case .partial: .partial
        }
    }
}

struct LiveTraceSnapshot: Sendable {
    let samples: [LiveTraceSample]
    let marks: [LiveTraceMarker]
}

/// Only this small view observes the per-frame signal. Its path is the engine's measured depth,
/// positioned on the capture clock; no idealized rep curve is substituted for the recording.
struct LiveMotionTrace: View {
    let signal: LiveSignal

    var body: some View {
        MotionTraceView(trace: signal.snapshot, recentSamples: 420, showsHead: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.44), in: .rect(cornerRadius: 28))
            .accessibilityLabel("Motion trace")
    }
}

struct MotionTraceView: View {
    let trace: LiveTraceSnapshot
    var recentSamples: Int? = nil
    var selectedRep: Int? = nil
    /// Marks the newest sample: where the person is right now.
    var showsHead = false

    private var samples: [LiveTraceSample] {
        if let recentSamples { Array(trace.samples.suffix(recentSamples)) } else { trace.samples }
    }

    var body: some View {
        GeometryReader { proxy in
            let points = samples
            let first = points.first?.time ?? 0
            let last = points.last?.time ?? 1
            let width = proxy.size.width
            let plotHeight = max(1, proxy.size.height - 24)
            let byID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    let countingDepth = 1 - MotionConfig.default.segmenter.bottomEnter
                    var threshold = Path()
                    let y = ordinate(countingDepth, height: plotHeight)
                    threshold.move(to: CGPoint(x: 0, y: y))
                    threshold.addLine(to: CGPoint(x: width, y: y))
                    context.stroke(threshold, with: .color(TraceTheme.blue), style: StrokeStyle(lineWidth: 1, dash: [4, 5]))
                    if let selectedRep,
                       let selected = trace.marks.first(where: { $0.number == selectedRep }), let sample = byID[selected.sampleID] {
                        let x = abscissa(sample.time, first: first, last: last, width: width)
                        var locator = Path()
                        locator.move(to: CGPoint(x: x, y: 0))
                        locator.addLine(to: CGPoint(x: x, y: plotHeight))
                        context.stroke(locator, with: .color(.white.opacity(0.25)), lineWidth: 1)
                    }
                    guard points.count > 1 else { return }
                    var line = Path()
                    for (offset, sample) in points.enumerated() {
                        let point = CGPoint(x: abscissa(sample.time, first: first, last: last, width: width),
                                            y: ordinate(sample.depth, height: plotHeight))
                        if offset == 0 { line.move(to: point) } else { line.addLine(to: point) }
                    }
                    context.stroke(line, with: .color(.white), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if showsHead, let head = points.last, points.count > 1 {
                    TraceHead(reps: trace.marks.count { $0.number != nil })
                        .position(x: abscissa(head.time, first: first, last: last, width: width),
                                  y: ordinate(head.depth, height: plotHeight))
                }
                ForEach(Array(trace.marks.enumerated()), id: \.offset) { _, mark in
                    if let sample = byID[mark.sampleID] {
                        let x = abscissa(sample.time, first: first, last: last, width: width)
                        let y = ordinate(sample.depth, height: plotHeight)
                        VStack(spacing: 3) {
                            TraceMark(status: mark.status)
                                .overlay {
                                    if let selectedRep, mark.number == selectedRep {
                                        Circle().stroke(.white, lineWidth: 2).padding(-4)
                                    }
                                }
                            if let number = mark.number {
                                Text(number, format: .number)
                                    .font(TraceTheme.numeral(13))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                        .position(x: x, y: y + (mark.number == nil ? 0 : 9))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func abscissa(_ time: TimeInterval, first: TimeInterval, last: TimeInterval, width: CGFloat) -> CGFloat {
        CGFloat((time - first) / max(0.001, last - first)) * width
    }

    private func ordinate(_ depth: Double, height: CGFloat) -> CGFloat {
        5 + CGFloat(min(1.15, max(0, depth))) / 1.15 * max(1, height - 10)
    }
}

/// The live end of the trace. Each counted rep sends one ripple out from it; the ripple is a spring released from
/// the head, and its fade is read from how far it has spread, so nothing here runs on a clock.
private struct TraceHead: View {
    let reps: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .shadow(color: .white.opacity(0.8), radius: 6)
            .background {
                if !reduceMotion {
                    Circle()
                        .fill(.white)
                        .keyframeAnimator(initialValue: 1.0, trigger: reps) { ring, spread in
                            ring
                                .scaleEffect(1 + 1.6 * spread)
                                .opacity(0.85 * (1 - min(1, spread)))
                        } keyframes: { _ in
                            MoveKeyframe(0)
                            SpringKeyframe(1, spring: TraceMotion.ripple)
                        }
                }
            }
    }
}
