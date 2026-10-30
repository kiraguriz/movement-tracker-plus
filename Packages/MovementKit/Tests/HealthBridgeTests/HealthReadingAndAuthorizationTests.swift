import Domain
import Foundation
import Testing
@testable import HealthBridge

/// A reader backed by values the test chooses; it records what it was asked.
actor FakeHealthReader: HealthReading {
    private var bodyMass: HealthBodyMassSample?
    private var steps: [LocalDay: Int]
    private var failure: (any Error)?
    private(set) var stepQueries: [(day: LocalDay, zone: String)] = []

    init(bodyMass: HealthBodyMassSample? = nil, steps: [LocalDay: Int] = [:], failure: (any Error)? = nil) {
        self.bodyMass = bodyMass
        self.steps = steps
        self.failure = failure
    }

    func latestBodyMass() async throws -> HealthBodyMassSample? {
        if let failure { throw failure }
        return bodyMass
    }

    func stepCount(on day: LocalDay, in timeZone: TimeZone) async throws -> Int? {
        if let failure { throw failure }
        stepQueries.append((day, timeZone.identifier))
        return steps[day]
    }
}

@Suite("Health reads")
struct HealthReadingTests {
    @Test func todaysStepsAskForTheLocalDayNotTheUTCDay() async throws {
        // 04:30Z on the 10th is 23:30 on the 9th in Chicago (CDT), 13:30 on the 10th in Tokyo.
        let now = instant("2026-03-10T04:30:00Z")
        let reader = FakeHealthReader(steps: [day("2026-03-09"): 8_421, day("2026-03-10"): 12])

        #expect(try await reader.stepsToday(now: now, in: Zones.chicago) == 8_421)
        #expect(try await reader.stepsToday(now: now, in: Zones.tokyo) == 12)
        #expect(try await reader.stepsToday(now: now, in: Zones.utc) == 12)
        let queries = await reader.stepQueries
        #expect(queries.map(\.zone) == [Zones.chicago.identifier, Zones.tokyo.identifier, Zones.utc.identifier])
        #expect(queries.map(\.day) == [day("2026-03-09"), day("2026-03-10"), day("2026-03-10")])
    }

    @Test func aDayWithoutStepsIsNilNotZero() async throws {
        let reader = FakeHealthReader(steps: [:])
        #expect(try await reader.stepsToday(now: Fixture.t0, in: Zones.chicago) == nil)
    }

    @Test func readFailuresPropagateToTheCaller() async {
        let reader = FakeHealthReader(failure: HealthAccessError.unavailable)
        await #expect(throws: HealthAccessError.unavailable) { try await reader.latestBodyMass() }
        await #expect(throws: HealthAccessError.unavailable) { try await reader.stepsToday(now: Fixture.t0) }
    }

    @Test func theLatestBodyMassCarriesWhatTheAppNeedsToImportItOnce() async throws {
        let sample = HealthBodyMassSample(mass: Mass(kilograms: 71.8), measuredAt: Fixture.t0, uuid: "HK-1")
        let reader = FakeHealthReader(bodyMass: sample)
        let read = try #require(try await reader.latestBodyMass())
        #expect(read.mass.kilograms == 71.8 && read.uuid == "HK-1")
        #expect(!read.isWrittenByThisApp, "no sync identifier: it came from another source")
        #expect(try await FakeHealthReader().latestBodyMass() == nil)
    }

    @Test func anExportedSampleIsRecognisedSoItIsNotImportedBack() {
        let own = HealthBodyMassSample(
            mass: Mass(kilograms: 80), measuredAt: Fixture.t0, uuid: "HK-2",
            syncIdentifier: HealthSyncIdentifier.object(.bodyMass, base: HealthSyncIdentifier.base(entity: .bodyMeasurement, entityID: "b1"))
        )
        let other = HealthBodyMassSample(mass: Mass(kilograms: 80), measuredAt: Fixture.t0, uuid: "HK-3", syncIdentifier: "com.other.scale.123")
        #expect(own.isWrittenByThisApp)
        #expect(!other.isWrittenByThisApp)
    }
}

@Suite("Authorization state")
struct HealthAuthorizationStateTests {
    private static func sharing(_ status: HealthSharingStatus, except: [HealthObjectKind: HealthSharingStatus] = [:]) -> [HealthObjectKind: HealthSharingStatus] {
        var all = Dictionary(uniqueKeysWithValues: HealthObjectKind.allCases.map { ($0, status) })
        for (kind, other) in except { all[kind] = other }
        return all
    }

    @Test func aDeviceWithoutHealthIsUnavailableWhateverElseIsTrue() {
        #expect(HealthAuthorizationState.resolve(isAvailable: false, shouldRequest: true, sharing: Self.sharing(.authorized)) == .unavailable)
    }

    @Test func aPendingRequestIsNotDeterminedEvenIfSomeTypesAreAlreadyAllowed() {
        // An update that adds a type makes Health ask again.
        let partly = Self.sharing(.authorized, except: [.dietaryFat: .notDetermined])
        #expect(HealthAuthorizationState.resolve(isAvailable: true, shouldRequest: true, sharing: partly) == .notDetermined)
        #expect(HealthAuthorizationState.resolve(isAvailable: true, shouldRequest: true, sharing: [:]) == .notDetermined)
    }

    @Test func everyTypeAllowedIsAuthorized() {
        let state = HealthAuthorizationState.resolve(isAvailable: true, shouldRequest: false, sharing: Self.sharing(.authorized))
        #expect(state == .authorized && state.canWrite)
    }

    @Test func everyTypeRefusedIsDenied() {
        let state = HealthAuthorizationState.resolve(isAvailable: true, shouldRequest: false, sharing: Self.sharing(.denied))
        #expect(state == .denied && !state.canWrite)
    }

    @Test func aMixIsPartialAndNamesWhatCannotBeWritten() {
        let mixed = Self.sharing(.authorized, except: [.dietaryProtein: .denied, .activeEnergy: .denied])
        let state = HealthAuthorizationState.resolve(isAvailable: true, shouldRequest: false, sharing: mixed)
        #expect(state == .partiallyAuthorized(denied: [.activeEnergy, .dietaryProtein]), "in the order of HealthObjectKind")
        #expect(!state.canWrite)
    }

    @Test func nothingAllowedAndNothingAskedYetIsNotDetermined() {
        let state = HealthAuthorizationState.resolve(isAvailable: true, shouldRequest: false, sharing: Self.sharing(.notDetermined))
        #expect(state == .notDetermined)
    }

    @Test func noTypesAtAllIsNotDeterminedRatherThanAuthorized() {
        #expect(HealthAuthorizationState.resolve(isAvailable: true, shouldRequest: false, sharing: [:]) == .notDetermined)
    }
}
