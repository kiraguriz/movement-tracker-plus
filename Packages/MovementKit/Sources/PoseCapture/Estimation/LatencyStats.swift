import Foundation

/// Percentiles of a set of durations, in seconds.
public struct LatencySummary: Equatable, Sendable {
    public var count: Int
    public var p50: Double
    public var p95: Double
    public var mean: Double
    public var max: Double

    public static let empty = LatencySummary(count: 0, p50: 0, p95: 0, mean: 0, max: 0)

    public init(count: Int, p50: Double, p95: Double, mean: Double, max: Double) {
        self.count = count
        self.p50 = p50
        self.p95 = p95
        self.mean = mean
        self.max = max
    }

    /// Summarizes `samples` (any order). Empty input gives `.empty`.
    public init(samples: [Double]) {
        guard !samples.isEmpty else {
            self = .empty
            return
        }
        let sorted = samples.sorted()
        self.init(
            count: sorted.count,
            p50: Self.percentile(sorted: sorted, 0.50),
            p95: Self.percentile(sorted: sorted, 0.95),
            mean: sorted.reduce(0, +) / Double(sorted.count),
            max: sorted[sorted.count - 1]
        )
    }

    /// Percentile `p` (0...1) of an ascending array, interpolating linearly between the two nearest ranks.
    public static func percentile(sorted: [Double], _ p: Double) -> Double {
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = Swift.min(Swift.max(p, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}

/// The most recent `capacity` durations, for live p50/p95.
public struct LatencyWindow: Sendable {
    private var samples: [Double] = []
    private var next = 0
    public let capacity: Int

    public init(capacity: Int = 120) {
        self.capacity = Swift.max(1, capacity)
        samples.reserveCapacity(self.capacity)
    }

    public var count: Int { samples.count }

    public mutating func record(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        if samples.count < capacity {
            samples.append(seconds)
        } else {
            samples[next] = seconds
            next = (next + 1) % capacity
        }
    }

    public var summary: LatencySummary { LatencySummary(samples: samples) }
}
