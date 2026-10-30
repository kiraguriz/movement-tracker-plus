import Foundation

/// Time, injected so retry waits can be tested without waiting.
public protocol CoachClock: Sendable {
    func now() -> Date
    /// Suspends for `duration`; throws `CancellationError` when the task is cancelled meanwhile.
    func sleep(for duration: Duration) async throws
}

public struct SystemCoachClock: CoachClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// A source of numbers in `0..<1` for backoff jitter, injected so tests are deterministic.
public protocol JitterSource: Sendable {
    func nextUnit() -> Double
}

public struct SystemJitter: JitterSource {
    public init() {}

    public func nextUnit() -> Double { Double.random(in: 0..<1) }
}

/// When and how long to wait before sending a request again.
///
/// Retried: 429 and 503 (waiting at least `Retry-After`) and network failures. Never retried: 400, 413, 502, 504
/// (Meta's non-streaming time limit; the same request would time out again), 401 (handled by one re-install), a 429
/// or 503 whose `Retry-After` is longer than `maxRetryAfter` or whose code is `daily_budget_exceeded` or
/// `service_paused`, and anything after a stream has started delivering text.
public struct RetryPolicy: Sendable, Equatable {
    /// Total tries including the first.
    public var maxAttempts: Int
    public var baseDelay: Duration
    public var maxDelay: Duration
    /// A `Retry-After` longer than this is not waited out; the error goes to the caller instead.
    public var maxRetryAfter: Duration

    public init(
        maxAttempts: Int = 4,
        baseDelay: Duration = .milliseconds(500),
        maxDelay: Duration = .seconds(8),
        maxRetryAfter: Duration = .seconds(45)
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxRetryAfter = maxRetryAfter
    }

    public static let standard = RetryPolicy()
    public static let none = RetryPolicy(maxAttempts: 1)

    /// The wait before retry number `retry` (1 for the first retry): `base * 2^(retry-1)` capped at `maxDelay`,
    /// then "equal jitter": somewhere between half of it and all of it, chosen by `unit` in `0..<1`.
    public func backoff(retry: Int, unit: Double) -> Duration {
        let base = baseDelay.seconds
        let exponent = Double(max(0, retry - 1))
        let capped = min(maxDelay.seconds, base * pow(2, min(exponent, 30)))
        let clampedUnit = min(max(unit, 0), 1)
        return .seconds(capped * (0.5 + 0.5 * clampedUnit))
    }
}

extension Duration {
    /// The duration in seconds as a double.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Parses a `Retry-After` header: whole seconds, or an HTTP date relative to `now`.
func parseRetryAfter(_ value: String?, now: Date) -> TimeInterval? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) {
        return TimeInterval(trimmed)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: trimmed) {
            return max(0, date.timeIntervalSince(now))
        }
    }
    return nil
}
