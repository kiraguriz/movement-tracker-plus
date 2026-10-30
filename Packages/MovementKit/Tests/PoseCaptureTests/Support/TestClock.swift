import Foundation
import Synchronization

/// A clock that runs on virtual time: `sleep(until:)` returns at once and moves `now` to the deadline,
/// recording what it was asked to wait for. A replay driven by it finishes immediately, and the test can
/// read back exactly how the replay paced itself.
final class TestClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var deadlines: [Instant] = []
    }

    private let state = Mutex(State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .nanoseconds(1) }

    /// Every deadline passed to `sleep(until:tolerance:)`, in order, in seconds since the clock's origin.
    var requestedDeadlines: [Double] { state.withLock { $0.deadlines.map { $0.offset.testSeconds } } }

    init(startingAt start: Duration = .seconds(100)) {
        state.withLock { $0.now = Instant(offset: start) }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        state.withLock {
            $0.deadlines.append(deadline)
            if deadline > $0.now { $0.now = deadline }
        }
    }

    /// Moves virtual time forward without anyone sleeping, as time passing before a replay gets going.
    func jump(by duration: Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }
}

/// A clock frozen at one instant: a deadline that is not in the future returns at once, any other sleep
/// waits until the task is cancelled. Lets a test see a replay stuck in a wait and then watch it get cancelled.
final class HangingClock: Clock, Sendable {
    typealias Instant = TestClock.Instant

    private struct State {
        var sleeping = 0
        var cancelled = 0
    }

    private let state = Mutex(State())
    let now = TestClock.Instant(offset: .seconds(100))
    var minimumResolution: Duration { .nanoseconds(1) }

    /// Sleeps currently waiting.
    var sleeping: Int { state.withLock { $0.sleeping } }
    /// Sleeps that ended because their task was cancelled.
    var cancelledSleeps: Int { state.withLock { $0.cancelled } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        guard deadline > now else { return }
        state.withLock { $0.sleeping += 1 }
        defer { state.withLock { $0.sleeping -= 1 } }
        do {
            while true {
                try await Task.sleep(for: .milliseconds(5))      // a real, cancellable wait
            }
        } catch {
            state.withLock { $0.cancelled += 1 }
            throw error
        }
    }
}

extension Duration {
    var testSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
