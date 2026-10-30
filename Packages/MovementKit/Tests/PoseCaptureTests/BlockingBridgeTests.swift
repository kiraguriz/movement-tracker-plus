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

@Suite("Blocking bridge")
struct BlockingBridgeTests {
    @Test func returnsTheOperationsValue() async {
        let bridge = BlockingBridge()
        let value = await onQueue { bridge.run(timeout: 5) { 42 } }
        #expect(value == 42)
        #expect(!bridge.hasAbandonedWork)
    }

    @Test func nilFromTheOperationIsNil() async {
        let bridge = BlockingBridge()
        let value: Int? = await onQueue { bridge.run(timeout: 5) { () async -> Int? in nil } }
        #expect(value == nil)
        #expect(!bridge.hasAbandonedWork)             // an answer of nil is not a timeout
    }

    @Test func aSlowOperationTimesOutAndTheCallerMovesOn() async throws {
        let bridge = BlockingBridge()
        let gate = Gate()
        let started = ContinuousClock.now
        let value = await onQueue { bridge.run(timeout: 0.05) { await gate.pass(); return 1 } }
        #expect(value == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
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

        // The capture queue would otherwise wait a full timeout on every frame behind the stuck call. Each
        // call gets a long timeout and must come back in under half of it. The bound is per call, so a
        // machine that is slow overall cannot trip it, and a call that waits for its timeout always does.
        let timeout = 10.0
        let ran = Mutex(0)
        for _ in 0..<20 {
            let began = ContinuousClock.now
            let value: Int? = await onQueue { bridge.run(timeout: timeout) { ran.withLock { $0 += 1 }; return 2 } }
            #expect(value == nil)
            let took = ContinuousClock.now - began
            #expect(took < .seconds(timeout / 2))
            if took >= .seconds(timeout / 2) { break }
        }
        #expect(ran.withLock { $0 } == 0)

        gate.open()
        for _ in 0..<500 where bridge.hasAbandonedWork { try await Task.sleep(for: .milliseconds(5)) }
        // Once the stuck work has finished the bridge works again.
        let value = await onQueue { bridge.run(timeout: 5) { 3 } }
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
        #expect(await onQueue { bridge.run(timeout: 5) { 9 } } == 9)
    }

    @Test func manyQuickCallsFromOneQueueAllComplete() async {
        let bridge = BlockingBridge()
        let sum = await onQueue {
            var total = 0
            for i in 0..<200 { total += bridge.run(timeout: 5) { i } ?? 0 }
            return total
        }
        #expect(sum == (0..<200).reduce(0, +))
    }
}
