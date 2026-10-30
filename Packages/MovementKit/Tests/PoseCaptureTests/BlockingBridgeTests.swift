import Dispatch
import Foundation
import Synchronization
import Testing
@testable import PoseCapture

/// A gate an operation can be held at until the test lets it go.
private final class Gate: Sendable {
    private let released = Mutex(false)
    private let started = Mutex(0)

    var startedCount: Int { started.withLock { $0 } }

    /// A bridge that ignored its timeout would block its test for good: the suite's time limit does not end a test
    /// whose thread waits on a semaphore. So the gate opens by itself long after a healthy test is done with it, the
    /// call returns the operation's value instead of nil, and the test fails instead of hanging.
    init() {
        Task { [self] in
            try? await Task.sleep(for: .seconds(20))
            open()
        }
    }

    func open() { released.withLock { $0 = true } }

    func pass() async {
        started.withLock { $0 += 1 }
        while !released.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(2)) }
    }
}

/// Runs `body` on a plain dispatch queue, the way a capture queue does, and returns its result.
private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "test.capture").async { continuation.resume(returning: body()) }
    }
}

/// The timeout of a call that is expected to succeed. It is a ceiling, not an expectation: the call returns as soon as
/// the operation does, so a very large value costs nothing and a loaded machine cannot turn the call into a timeout.
private let ceiling = 60.0

@Suite("Blocking bridge", .timeLimit(.minutes(1)))
struct BlockingBridgeTests {
    @Test func returnsTheOperationsValue() async {
        let bridge = BlockingBridge()
        let value = await onQueue { bridge.run(timeout: ceiling) { 42 } }
        #expect(value == 42)
        #expect(!bridge.hasAbandonedWork)
    }

    @Test func nilFromTheOperationIsNil() async {
        let bridge = BlockingBridge()
        let value: Int? = await onQueue { bridge.run(timeout: ceiling) { () async -> Int? in nil } }
        #expect(value == nil)
        #expect(!bridge.hasAbandonedWork)             // an answer of nil is not a timeout
    }

    @Test func aSlowOperationTimesOutAndTheCallerMovesOn() async throws {
        let bridge = BlockingBridge()
        let gate = Gate()
        // The gate stays shut until this test opens it, below. So the call can only come back with nil and an
        // abandoned operation if it stopped waiting for the work; a call that waited would never return.
        let value = await onQueue { bridge.run(timeout: 0.05) { await gate.pass(); return 1 } }
        #expect(value == nil)
        #expect(bridge.hasAbandonedWork)
        gate.open()
        for _ in 0..<500 where bridge.hasAbandonedWork { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!bridge.hasAbandonedWork)
    }

    @Test func whileAbandonedWorkIsRunningNewCallsReturnAtOnceWithoutStartingMore() async throws {
        let bridge = BlockingBridge()
        let gate = Gate()
        _ = await onQueue { bridge.run(timeout: 0.02) { await gate.pass(); return 1 } }
        // On a busy machine the stuck call's task may not have been scheduled yet when its short wait ends.
        for _ in 0..<1000 where gate.startedCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.startedCount == 1)

        // The capture queue would otherwise wait a full timeout on every frame behind the stuck call. These calls
        // must come back at once without starting their operation. Had one started it, the operation would have
        // finished at once and the call would have answered 2: only the early return answers nil without running it.
        let ran = Mutex(0)
        for _ in 0..<20 {
            let value: Int? = await onQueue { bridge.run(timeout: ceiling) { ran.withLock { $0 += 1 }; return 2 } }
            #expect(value == nil)
        }
        #expect(ran.withLock { $0 } == 0)

        gate.open()
        for _ in 0..<500 where bridge.hasAbandonedWork { try await Task.sleep(for: .milliseconds(5)) }
        // Once the stuck work has finished the bridge works again.
        let value = await onQueue { bridge.run(timeout: ceiling) { 3 } }
        #expect(value == 3)
    }

    @Test func aValueThatArrivesAfterTheDeadlineIsDroppedWithoutCorruptingTheCount() async throws {
        let bridge = BlockingBridge()
        for _ in 0..<5 {
            let gate = Gate()
            _ = await onQueue { bridge.run(timeout: 0.01) { await gate.pass(); return 1 } }
            gate.open()
            for _ in 0..<500 where bridge.hasAbandonedWork { try await Task.sleep(for: .milliseconds(2)) }
            #expect(!bridge.hasAbandonedWork)
        }
        #expect(await onQueue { bridge.run(timeout: ceiling) { 9 } } == 9)
    }

    @Test func manyQuickCallsFromOneQueueAllComplete() async {
        let bridge = BlockingBridge()
        let sum = await onQueue {
            var total = 0
            for i in 0..<200 { total += bridge.run(timeout: ceiling) { i } ?? 0 }
            return total
        }
        #expect(sum == (0..<200).reduce(0, +))
    }
}
