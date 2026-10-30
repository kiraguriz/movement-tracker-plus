import Foundation
import Testing
@testable import Domain

@Suite("UUIDv7 identifiers")
struct IdentifierTests {
    @Test func generatedIdsHaveCanonicalUUIDv7Format() {
        let generator = UUIDv7Generator()
        let pattern = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
        for _ in 0..<1000 {
            let id = generator.makeID().rawValue
            #expect(id.wholeMatch(of: pattern) != nil, "\(id)")
            #expect(UUIDv7.isValid(id))
        }
    }

    @Test func formatsKnownVector() {
        let id = UUIDv7.make(unixMilliseconds: 0x018F_0000_1234, counter: 0xABC, random: 0)
        #expect(id == "018f0000-1234-7abc-8000-000000000000")
        let allOnes = UUIDv7.make(unixMilliseconds: UInt64.max, counter: UInt16.max, random: UInt64.max)
        #expect(allOnes == "ffffffff-ffff-7fff-bfff-ffffffffffff")
    }

    @Test func embedsTheTimestamp() {
        let clock = ManualClock(1_788_000_000_123)
        let id = UUIDv7Generator(clock: { clock.read() }).makeID()
        #expect(UUIDv7.unixMilliseconds(of: id.rawValue) == 1_788_000_000_123)
        #expect(id.embeddedDate == Date(timeIntervalSince1970: 1_788_000_000.123))
    }

    @Test func idsFromLaterMillisecondsSortAfterEarlierOnes() {
        let clock = ManualClock(1_700_000_000_000)
        let generator = UUIDv7Generator(clock: { clock.read() })
        var ids: [EntityID] = []
        for step in 0..<200 {
            clock.set(1_700_000_000_000 + UInt64(step) * 7)
            ids.append(generator.makeID())
        }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }

    @Test func idsStayStrictlyIncreasingWithinOneMillisecond() {
        // A frozen clock forces the counter to run and then borrow the next millisecond.
        let generator = UUIDv7Generator(clock: { 1_700_000_000_000 })
        var previous = generator.makeID()
        for _ in 0..<6000 {
            let next = generator.makeID()
            #expect(next > previous)
            #expect(UUIDv7.isValid(next.rawValue))
            previous = next
        }
    }

    @Test func idsStayIncreasingWhenTheClockGoesBackwards() {
        let clock = ManualClock(2_000_000_000_000)
        let generator = UUIDv7Generator(clock: { clock.read() })
        let first = generator.makeID()
        clock.set(1_000_000_000_000)
        let second = generator.makeID()
        #expect(second > first)
    }

    @Test func tightLoopOnTheSystemClockIsOrdered() {
        let generator = UUIDv7Generator()
        let ids = (0..<20_000).map { _ in generator.makeID() }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == ids.count)
    }

    @Test func concurrentCallersGetUniqueIdsAndEachCallersIdsIncrease() async {
        // A frozen clock forces every caller through the same counter, so any missing lock shows up as a duplicate.
        let generator = UUIDv7Generator(clock: { 1_700_000_000_000 })
        let batches = await withTaskGroup(of: [EntityID].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<3000).map { _ in generator.makeID() } }
            }
            var all: [[EntityID]] = []
            for await batch in group { all.append(batch) }
            return all
        }
        for batch in batches { #expect(batch == batch.sorted()) }
        let flat = batches.flatMap { $0 }
        #expect(flat.count == 24_000)
        #expect(Set(flat).count == flat.count)
        #expect(flat.allSatisfy { UUIDv7.isValid($0.rawValue) })
    }

    @Test func theSharedGeneratorIsSafeAcrossThreads() async {
        let batches = await withTaskGroup(of: [EntityID].self) { group in
            for _ in 0..<8 {
                group.addTask { (0..<2000).map { _ in EntityID.generate() } }
            }
            var all: [[EntityID]] = []
            for await batch in group { all.append(batch) }
            return all
        }
        let flat = batches.flatMap { $0 }
        #expect(Set(flat).count == flat.count)
        for batch in batches { #expect(batch == batch.sorted()) }
    }

    @Test func aBurstBeyondTheCounterBorrowsTimeInsteadOfRepeating() {
        let generator = UUIDv7Generator(clock: { 1_700_000_000_000 })
        let ids = (0..<20_000).map { _ in generator.makeID() }
        #expect(Set(ids).count == ids.count)
        let milliseconds = ids.compactMap { UUIDv7.unixMilliseconds(of: $0.rawValue) }
        #expect(milliseconds == milliseconds.sorted())
        // 20,000 ids at 4,096 per millisecond need at least five borrowed milliseconds.
        #expect((milliseconds.last ?? 0) - 1_700_000_000_000 >= 4)
    }

    @Test func versionAndVariantBitsAreSetOnEveryId() {
        let generator = UUIDv7Generator()
        for _ in 0..<2000 {
            let bytes = Array(generator.makeID().rawValue.utf8)
            #expect(bytes[14] == UInt8(ascii: "7"))
            #expect([UInt8(ascii: "8"), UInt8(ascii: "9"), UInt8(ascii: "a"), UInt8(ascii: "b")].contains(bytes[19]))
        }
    }

    @Test(arguments: [
        "",
        "018f0000-1234-7abc-8000-00000000000",       // too short
        "018F0000-1234-7ABC-8000-000000000000",       // upper case
        "018f0000-1234-4abc-8000-000000000000",       // version 4
        "018f0000-1234-7abc-c000-000000000000",       // variant 11
        "018f0000_1234_7abc_8000_000000000000",       // separators
        "018f0000-1234-7abc-8000-00000000000g",       // not hex
    ])
    func rejectsMalformedIds(_ candidate: String) {
        #expect(!UUIDv7.isValid(candidate))
        #expect(UUIDv7.unixMilliseconds(of: candidate) == nil)
    }

    @Test func entityIDEncodesAsABareString() throws {
        let id = EntityID("018f0000-1234-7abc-8000-000000000000")
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == "[\"018f0000-1234-7abc-8000-000000000000\"]")
        #expect(try JSONDecoder().decode([EntityID].self, from: data) == [id])
    }

    @Test func exerciseIDsAreSlugsAndEncodeAsStrings() throws {
        let id: ExerciseID = "squat.bodyweight"
        #expect(id.description == "squat.bodyweight")
        let data = try JSONEncoder().encode([id])
        #expect(try JSONDecoder().decode([ExerciseID].self, from: data) == [id])
    }
}
