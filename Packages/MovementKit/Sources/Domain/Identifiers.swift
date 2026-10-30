import Foundation

/// A source of new entity ids. Injected so reducers and tests stay deterministic.
public protocol IDGenerating: Sendable {
    func makeID() -> EntityID
}

/// Identifier of a stored entity: a canonical lowercase UUIDv7 string (RFC 9562).
/// The first 48 bits are a Unix millisecond timestamp, so string order is creation order.
public struct EntityID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: EntityID, rhs: EntityID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// A fresh id from the process-wide monotonic generator.
    public static func generate() -> EntityID {
        UUIDv7Generator.shared.makeID()
    }

    /// The creation instant embedded in the id, or nil when the id is not a UUIDv7.
    public var embeddedDate: Date? {
        UUIDv7.unixMilliseconds(of: rawValue).map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}

/// Identifier of an exercise: a stable dotted slug such as `squat.bodyweight`.
/// Built-in slugs that have a camera spec match the MotionCore spec id.
public struct ExerciseID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: ExerciseID, rhs: ExerciseID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// UUIDv7 formatting and parsing.
public enum UUIDv7 {
    /// Builds the canonical string `tttttttt-tttt-7ccc-vrrr-rrrrrrrrrrrr`.
    /// - Parameters:
    ///   - unixMilliseconds: low 48 bits are used.
    ///   - counter: low 12 bits fill `rand_a`; the generator uses it as a per-millisecond counter.
    ///   - random: low 62 bits fill `rand_b`; the variant bits `10` are set here.
    public static func make(unixMilliseconds: UInt64, counter: UInt16, random: UInt64) -> String {
        let milliseconds = unixMilliseconds & 0xFFFF_FFFF_FFFF
        let versionAndCounter = 0x7000 | UInt64(counter & 0x0FFF)
        let tail = (random & 0x3FFF_FFFF_FFFF_FFFF) | 0x8000_0000_0000_0000
        return [
            hex(milliseconds >> 16, width: 8),
            hex(milliseconds & 0xFFFF, width: 4),
            hex(versionAndCounter, width: 4),
            hex(tail >> 48, width: 4),
            hex(tail & 0xFFFF_FFFF_FFFF, width: 12),
        ].joined(separator: "-")
    }

    /// True for a canonical lowercase UUIDv7 string with the RFC 4122 variant.
    public static func isValid(_ string: String) -> Bool {
        let bytes = Array(string.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                if byte != UInt8(ascii: "-") { return false }
            default:
                let isDigit = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                let isLowerHex = (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                if !isDigit && !isLowerHex { return false }
            }
        }
        guard bytes[14] == UInt8(ascii: "7") else { return false }
        return [UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")].contains(bytes[19])
    }

    /// The embedded Unix millisecond timestamp, or nil when `string` is not a valid UUIDv7.
    public static func unixMilliseconds(of string: String) -> UInt64? {
        guard isValid(string) else { return nil }
        let digits = string.replacingOccurrences(of: "-", with: "").prefix(12)
        return UInt64(digits, radix: 16)
    }

    private static func hex(_ value: UInt64, width: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}

/// Generates strictly increasing UUIDv7 ids, also within one millisecond and across clock rollbacks.
/// `rand_a` is a counter (RFC 9562 method 1); when it overflows, the timestamp borrows the next millisecond.
public final class UUIDv7Generator: IDGenerating, @unchecked Sendable {
    public static let shared = UUIDv7Generator()

    private let clock: @Sendable () -> UInt64
    private let lock = NSLock()
    private var lastMilliseconds: UInt64 = 0
    private var counter: UInt16 = 0

    /// - Parameter clock: Unix milliseconds. Defaults to the system clock.
    public init(clock: @escaping @Sendable () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }) {
        self.clock = clock
    }

    public func makeID() -> EntityID {
        lock.withLock {
            let now = clock()
            if now > lastMilliseconds {
                lastMilliseconds = now
                // Leave the upper half of the counter range as headroom for same-millisecond ids.
                counter = UInt16.random(in: 0..<0x0800)
            } else if counter < 0x0FFF {
                counter += 1
            } else {
                lastMilliseconds += 1
                counter = UInt16.random(in: 0..<0x0800)
            }
            return EntityID(UUIDv7.make(
                unixMilliseconds: lastMilliseconds,
                counter: counter,
                random: UInt64.random(in: .min ... .max)
            ))
        }
    }
}
