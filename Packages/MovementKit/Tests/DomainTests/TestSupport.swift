import Foundation
@testable import Domain

/// Deterministic ids for reducer tests: UUIDv7-shaped and strictly increasing.
final class SequentialIDs: IDGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt16 = 0

    func makeID() -> EntityID {
        lock.withLock {
            next += 1
            return EntityID(UUIDv7.make(unixMilliseconds: 1_700_000_000_000, counter: next, random: 0))
        }
    }
}

/// A clock the test moves by hand.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64

    init(_ value: UInt64) { self.value = value }

    func set(_ newValue: UInt64) { lock.withLock { value = newValue } }
    func read() -> UInt64 { lock.withLock { value } }
}

enum Zones {
    static let chicago = TimeZone(identifier: "America/Chicago")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let kiritimati = TimeZone(identifier: "Pacific/Kiritimati")!
    static let pagoPago = TimeZone(identifier: "Pacific/Pago_Pago")!
    static let utc = TimeZone(identifier: "UTC")!
}

/// An ISO 8601 instant such as `2026-03-09T04:30:00Z`.
func instant(_ iso: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: iso)!
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
