import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Observation")
struct ObservationTests {
    /// Waits for `task` to finish, or reports that it did not within `timeout`.
    private func finishes(_ task: Task<Void, Never>, within timeout: Duration = .seconds(5)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await task.value; return true }
            group.addTask { try? await Task.sleep(for: timeout); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    @Test func cancellingTheConsumerEndsTheStream() async throws {
        let database = try makeDatabase()
        let stream = database.settings.observeValue(forKey: "k")
        let received = Tally()
        let consumer = Task {
            do {
                for try await _ in stream { received.add(1) }
            } catch {}
        }
        #expect(await waitUntil { received.value >= 1 }, "the current value arrives first")
        consumer.cancel()
        #expect(await finishes(consumer), "a cancelled consumer must not hang on the stream")
    }

    @Test func cancellingStopsDeliveryEvenWhileWritesContinue() async throws {
        try await withTemporaryDirectory { directory in
            let database = try AppDatabase.open(at: directory.appendingPathComponent("app.sqlite"))
            let received = Tally()
            let consumer = Task {
                do {
                    for try await _ in database.settings.observeValue(forKey: "k") { received.add(1) }
                } catch {}
            }
            #expect(await waitUntil { received.value >= 1 }, "the current value arrives first")
            try await database.settings.set(SettingKey<Int>("k", default: 0), to: 1)
            consumer.cancel()
            #expect(await finishes(consumer))
            let seen = received.value
            for value in 2...6 { try await database.settings.set(SettingKey<Int>("k", default: 0), to: value) }
            try await Task.sleep(for: .milliseconds(200))
            #expect(received.value == seen, "no value is delivered after cancellation")
        }
    }

    @Test func aPoolObservationSeesWritesFromAnotherConnection() async throws {
        try await withTemporaryDirectory { directory in
            let database = try AppDatabase.open(at: directory.appendingPathComponent("app.sqlite"))
            let collector = Collector(database.nutrition.observeDayTotals(from: Fixture.day("2026-10-01"), through: Fixture.day("2026-10-31")))
            try await collector.wait(count: 1)
            let meal = MealEntry(
                id: "m1", localDay: Fixture.day("2026-10-29"), slot: .lunch, label: "Rice", grams: Mass(grams: 100),
                nutrients: Nutrients(energy: Energy(kilocalories: 130)), source: .manual, loggedAt: Fixture.t0, timeZoneID: "UTC"
            )
            try await database.nutrition.log([meal], foods: [])
            let values = try await collector.wait(count: 2)
            #expect(values[0].isEmpty)
            #expect(values[1].first?.nutrients.energy == Energy(kilocalories: 130))
        }
    }

    @Test func aFailingFetchEndsTheStreamWithTheErrorInsteadOfHanging() async throws {
        let database = try makeDatabase()
        // A corrupt stored day cannot be written through the API (CHECK constraint), so plant one by hand.
        try await database.writer.write { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(sql: """
                INSERT INTO meal_entry (id, local_day, slot, label, grams, source, logged_at, tz)
                VALUES ('bad', '2026-11-45', 'lunch', 'Broken', 1, 'manual', '2026-10-29 12:00:00.000', 'UTC')
                """)
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        let stream = database.nutrition.observeDayTotals(from: Fixture.day("2026-01-01"), through: Fixture.day("2026-12-31"))
        let failed = Tally()
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {
                failed.add(1)
            }
        }
        #expect(await finishes(consumer), "the stream ends")
        #expect(failed.value == 1, "and it ends with the error")
    }
}
