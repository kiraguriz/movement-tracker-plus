import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Deterministic UUIDv7-shaped ids that increase with every call.
final class SequentialIDs: IDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt16 = 0

    func makeID() -> EntityID {
        lock.withLock {
            next += 1
            return EntityID(UUIDv7.make(unixMilliseconds: 1_790_000_000_000, counter: next, random: 0))
        }
    }
}

enum Fixture {
    /// Whole seconds, so dates survive the database's millisecond text format exactly.
    static let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    static let chicago = TimeZone(identifier: "America/Chicago")!
    static let utc = TimeZone(identifier: "UTC")!

    static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    static func day(_ text: String) -> LocalDay { LocalDay(text)! }

    static func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    static func rep(_ index: Int, score: Int = 90, issues: [RepIssue] = []) -> RepMeasurement {
        RepMeasurement(
            index: index, tStart: Double(index) * 3, tBottom: Double(index) * 3 + 1.25, tEnd: Double(index) * 3 + 2.5,
            eccentricMilliseconds: 1250, concentricMilliseconds: 1250, rom: 0.8125, bottomValue: 0.0625,
            concentricVelocity: 0.6, score: score, issues: issues,
            metrics: ["maxTorsoLeanDeg@descent": 32.5, "eccMs": 1250]
        )
    }
}

/// A fresh in-memory database for one test.
func makeDatabase() throws -> AppDatabase {
    try AppDatabase.inMemory()
}

/// A unique temporary directory, removed when `body` finishes.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MovementKitTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}

struct TimedOut: Error, CustomStringConvertible {
    var description: String
}

/// Consumes an observation in the background so tests can wait for emissions without hanging.
final class Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    private var failure: (any Error)?
    private var task: Task<Void, Never>?

    init(_ stream: ValueStream<Value>) {
        task = Task { [weak self] in
            do {
                for try await value in stream {
                    self?.append(value)
                }
            } catch {
                self?.fail(error)
            }
        }
    }

    deinit { task?.cancel() }

    private func append(_ value: Value) { lock.withLock { storage.append(value) } }
    private func fail(_ error: any Error) { lock.withLock { failure = error } }

    var values: [Value] { lock.withLock { storage } }

    /// Waits until `count` values have arrived (or the predicate holds on the values so far).
    @discardableResult
    func wait(count: Int, timeout: Duration = .seconds(5)) async throws -> [Value] {
        try await wait(timeout: timeout, description: "\(count) values") { $0.count >= count }
    }

    @discardableResult
    func wait(timeout: Duration = .seconds(5), description: String = "condition", until predicate: ([Value]) -> Bool) async throws -> [Value] {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (snapshot, error) = lock.withLock { (storage, failure) }
            if let error { throw error }
            if predicate(snapshot) { return snapshot }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw TimedOut(description: "Timed out waiting for \(description); got \(values.count) values")
    }

    /// Asserts that nothing more arrives for a short while.
    func expectQuiet(for duration: Duration = .milliseconds(250)) async throws -> Int {
        let before = values.count
        try await Task.sleep(for: duration)
        return values.count - before
    }

    func cancel() { task?.cancel() }
}

/// Polls until `condition` holds, so tests do not depend on how quickly a busy machine delivers a value.
func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

extension AppDatabase {
    /// Row counts of the named tables, for cascade and atomicity checks.
    func count(_ table: String) throws -> Int {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }
}

/// A seeded generator, so a failing random case can be replayed.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
