import Dispatch
import Foundation
import Synchronization

/// Runs async work from a serial capture queue and waits for the result, so a camera frame never has to
/// leave the queue it arrived on.
///
/// Only for a thread that is not part of Swift concurrency: a capture queue. Calling it from the main
/// thread freezes the UI for as long as the work runs, and calling it from a task parks a thread of the
/// cooperative pool that the work itself may need; both are asserted against in debug builds.
///
/// The wait is bounded. When the work does not finish in time the caller moves on with nil, but the work
/// keeps running, so while any abandoned call is still unfinished new calls return nil at once instead of
/// queueing more work behind it and blocking the capture queue for a full timeout on every frame.
final class BlockingBridge: Sendable {
    /// Calls that timed out and have not finished yet. A counter, because the caller that gives up and the
    /// work that finishes can update it in either order.
    private let abandoned = Mutex(0)

    var hasAbandonedWork: Bool { abandoned.withLock { $0 > 0 } }

    /// The operation's result, or nil if it returned nil, did not finish within `timeout` seconds, or an
    /// earlier call is still running.
    func run<Value: Sendable>(
        timeout: TimeInterval, _ operation: @escaping @Sendable () async -> Value?
    ) -> Value? {
        assert(!Thread.isMainThread, "BlockingBridge.run would block the main thread")
        assert(withUnsafeCurrentTask { $0 == nil }, "BlockingBridge.run would block a thread of Swift concurrency")
        guard !hasAbandonedWork else { return nil }

        let rendezvous = Rendezvous<Value?>()
        Task.detached(priority: .userInitiated) { [self] in
            let value = await operation()
            if rendezvous.fulfill(value) { abandoned.withLock { $0 -= 1 } }
        }
        switch rendezvous.wait(timeout: timeout) {
        case let .value(value):
            return value
        case .timedOut:
            abandoned.withLock { $0 += 1 }
            return nil
        }
    }
}

/// One-shot hand-off from a task to a blocked thread.
private final class Rendezvous<Value: Sendable>: Sendable {
    enum Outcome {
        case value(Value)
        case timedOut
    }

    private enum Slot {
        case waiting
        case done(Value)
        case abandoned
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let slot = Mutex(Slot.waiting)

    /// Stores the value. True if the waiter had already given up, so the value is thrown away.
    func fulfill(_ value: Value) -> Bool {
        let wasAbandoned = slot.withLock { slot -> Bool in
            if case .abandoned = slot { return true }
            slot = .done(value)
            return false
        }
        semaphore.signal()
        return wasAbandoned
    }

    func wait(timeout: TimeInterval) -> Outcome {
        _ = semaphore.wait(timeout: .now() + max(0, timeout))
        // Decide under the lock, so a value that arrives right at the deadline is not lost and a value that
        // arrives after it is known to be late.
        return slot.withLock { slot -> Outcome in
            if case let .done(value) = slot { return .value(value) }
            slot = .abandoned
            return .timedOut
        }
    }
}
