import Domain
import Foundation
import Persistence
import Testing
@testable import HealthBridge

private actor SyncTestBridge: HealthWriting, HealthAuthorizing {
    let writer = FakeHealthWriter()
    var state = HealthAuthorizationState.authorized
    func authorizationState() async -> HealthAuthorizationState { state }
    func requestAuthorization() async throws -> HealthAuthorizationState { state }
    func write(_ plan: HealthWritePlan) async throws -> HealthWriteReceipt { try await writer.write(plan) }
    func remove(_ objects: [HealthObjectRef]) async throws { try await writer.remove(objects) }
    func setState(_ value: HealthAuthorizationState) { state = value }
}

@Suite("App Health coordinator")
struct HealthSyncServiceTests {
    private func service(_ database: AppDatabase, _ bridge: SyncTestBridge) -> HealthSync {
        HealthSync(exports: database.healthExports, workouts: database.workouts, nutrition: database.nutrition,
                   bodyMeasurements: database.bodyMeasurements, settings: database.settings,
                   bridge: bridge, now: { Fixture.t0 })
    }

    @Test func activationFindsAnIntentEvenIfTheSaveNeverSentAWakeup() async throws {
        let database = try AppDatabase.inMemory()
        try await database.settings.set(.appleHealth, to: true)
        let meal = Fixture.meal("m1")
        try await database.nutrition.log([meal], foods: [])
        let bridge = SyncTestBridge()
        let sync = service(database, bridge)
        await sync.synchronize()
        #expect(await bridge.writer.objects.count == 4)
        #expect(try await database.healthExports.outstanding(limit: 10).isEmpty)
    }

    @Test func repeatedWakeupsDoNotQueueAnotherRevisionOrDuplicateTheWrite() async throws {
        let database = try AppDatabase.inMemory()
        try await database.settings.set(.appleHealth, to: true)
        let meal = Fixture.meal("m1")
        try await database.nutrition.log([meal], foods: [])
        let bridge = SyncTestBridge()
        let sync = service(database, bridge)
        sync.saved(.meal(meal))
        sync.saved(.meal(meal))
        await sync.synchronize()
        #expect(await bridge.writer.plans.count == 1)
        #expect(try await database.healthExports.export(entity: .meal, entityID: meal.id)?.syncVersion == 1)
    }

    @Test func aDeleteThatFailedWhileExportsWereOffRetriesWithoutTurningThemOn() async throws {
        let database = try AppDatabase.inMemory()
        try await database.settings.set(.appleHealth, to: true)
        let meal = Fixture.meal("m1")
        try await database.nutrition.log([meal], foods: [])
        let bridge = SyncTestBridge()
        let sync = service(database, bridge)
        await sync.synchronize()
        try await database.settings.set(.appleHealth, to: false)
        try await database.nutrition.deleteMeal(id: meal.id)
        await bridge.writer.failNext(HealthAccessError.temporarilyUnavailable)
        await sync.synchronize()
        #expect(await bridge.writer.objects.count == 4)
        #expect(try await database.healthExports.outstanding(limit: 10).count == 1)
        await sync.synchronize()
        #expect(await bridge.writer.objects.isEmpty)
        #expect(try await !database.settings.get(.appleHealth))
        #expect(try await database.healthExports.outstanding(limit: 10).isEmpty)
    }

    @Test func aPendingLiveEntityIsNotWrittenByARemovalDrainWhileOff() async throws {
        let database = try AppDatabase.inMemory()
        try await database.settings.set(.appleHealth, to: true)
        try await database.nutrition.log([Fixture.meal("m1")], foods: [])
        try await database.settings.set(.appleHealth, to: false)
        let bridge = SyncTestBridge()
        let sync = service(database, bridge)
        await sync.synchronize()
        #expect(await bridge.writer.objects.isEmpty)
        #expect(try await database.healthExports.outstanding(limit: 10).count == 1)
        #expect(try await sync.enable())
        await sync.synchronize()
        #expect(await bridge.writer.objects.count == 4)
    }

    @Test func anIntentAndConsentSurviveClosingAndReopeningTheDatabase() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HealthOutbox-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("app.sqlite")
        do {
            let first = try AppDatabase.open(at: url)
            try await first.settings.set(.appleHealth, to: true)
            try await first.nutrition.log([Fixture.meal("m1")], foods: [])
        }
        let reopened = try AppDatabase.open(at: url)
        let bridge = SyncTestBridge()
        let sync = service(reopened, bridge)
        await sync.synchronize()
        #expect(await bridge.writer.objects.count == 4)
        #expect(try await reopened.healthExports.outstanding(limit: 10).isEmpty)
    }
}
