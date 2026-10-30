import Domain
import Foundation
import Testing
@testable import HealthBridge

/// The energy estimate counts a session's training time, not whatever time passed before someone tapped Finish.
@Suite("Workout energy: idle time and bounds")
struct WorkoutEnergyBoundsTests {
    static let export = Fixture.export(.workout, "w1")

    private func at(_ minutes: Double) -> Date { Fixture.t0.addingTimeInterval(minutes * 60) }

    private func session(minutes: Double) -> WorkoutSession { Fixture.session("w1", start: Fixture.t0, minutes: minutes) }

    /// A set from minute `from` to minute `to`.
    private func timed(_ id: String, _ from: Double, _ to: Double) -> SetEntry {
        Fixture.set(EntityID(id), from: at(from), to: at(to))
    }

    private func plan(_ workout: Workout, kilograms: Double = 80) throws -> HealthWorkoutDraft {
        try #require(try HealthMapper.plan(for: workout, export: Self.export, bodyMass: Mass(kilograms: kilograms)).workout)
    }

    /// 4 METs above rest × 80 kg × `minutes` / 60.
    private func kilocalories(minutes: Double) -> Double { 4 * 80 * minutes / 60 }

    @Test func anOrdinarySessionCountsItsWholeLength() throws {
        // A one-minute set every five minutes: the rests are four minutes, well inside the idle limit.
        let sets = (0..<12).map { timed("s\($0)", 2 + Double($0) * 5, 3 + Double($0) * 5) }
        let draft = try plan(Fixture.workout(session(minutes: 60), sets: sets))
        #expect(abs((draft.samples.first?.value ?? 0) - kilocalories(minutes: 60)) < 1e-9)
    }

    @Test func aSessionFinishedTheNextMorningCountsOnlyItsActiveStretch() throws {
        // Three one-minute sets in the first quarter hour; Finish is tapped 16 hours after the start.
        let sets = [timed("s0", 2, 3), timed("s1", 8, 9), timed("s2", 15, 16)]
        let draft = try plan(Fixture.workout(session(minutes: 16 * 60), sets: sets))
        // 2 before the first set, three sets, rests of 5 and 6, and 10 of the 944 minutes after the last.
        let counted = 2.0 + 1 + 5 + 1 + 6 + 1 + 10
        let energy = try #require(draft.samples.first)
        #expect(abs(energy.value - kilocalories(minutes: counted)) < 1e-9)
        #expect(energy.metadata[HealthMetadataKey.energySeconds] == .double(counted * 60))
        #expect(draft.metadata[HealthMetadataKey.energySeconds] == .double(counted * 60))
        #expect(draft.end.timeIntervalSince(draft.start) == 16 * 3600, "the workout itself keeps the session's own interval")
    }

    @Test func aLongRestIsCountedUpToTheIdleLimit() throws {
        // 0–1, then 40 minutes of nothing, then 41–42 of a 45-minute session.
        let draft = try plan(Fixture.workout(session(minutes: 45), sets: [timed("s0", 0, 1), timed("s1", 41, 42)]))
        // 1 + 10 (of 40) + 1 + 3 (the tail)
        #expect(abs((draft.samples.first?.value ?? 0) - kilocalories(minutes: 15)) < 1e-9)
    }

    @Test func setsWithoutTimesFallBackToTheElapsedTimeUnderTheCap() throws {
        let overnight = try plan(Fixture.workout(session(minutes: 16 * 60)))
        #expect(abs((overnight.samples.first?.value ?? 0) - kilocalories(minutes: 180)) < 1e-9, "capped at three hours")
        #expect(overnight.samples.first?.metadata[HealthMetadataKey.energySeconds] == .double(HealthMapper.maxEnergyDuration))

        let ordinary = try plan(Fixture.workout(session(minutes: 120)))
        #expect(abs((ordinary.samples.first?.value ?? 0) - kilocalories(minutes: 120)) < 1e-9, "under the cap it is the elapsed time")
    }

    @Test func oneUntimedSetMeansNoSetIsTrusted() throws {
        // The timed sets alone would suggest a short session, but an untimed one may have happened anywhere.
        let sets = [timed("s0", 2, 3), Fixture.set("s1")]
        let draft = try plan(Fixture.workout(session(minutes: 16 * 60), sets: sets))
        #expect(abs((draft.samples.first?.value ?? 0) - kilocalories(minutes: 180)) < 1e-9)
    }

    @Test func aSetWithOneTimeIsAMoment() throws {
        // Only the end times were logged: 10 and 20 in a 30-minute session leaves ten-minute gaps all round.
        let sets = [Fixture.set("s0", to: at(10)), Fixture.set("s1", from: at(20))]
        let draft = try plan(Fixture.workout(session(minutes: 30), sets: sets))
        #expect(abs((draft.samples.first?.value ?? 0) - kilocalories(minutes: 30)) < 1e-9)
    }

    @Test func overlappingSetsAreNotCountedTwiceAndOrderDoesNotMatter() throws {
        // 10–20 and 15–25 are 15 active minutes; the later one comes first in the list.
        let draft = try plan(Fixture.workout(session(minutes: 30), sets: [timed("s1", 15, 25), timed("s0", 10, 20)]))
        // 10 before, 15 of sets, 5 after
        #expect(abs((draft.samples.first?.value ?? 0) - kilocalories(minutes: 30)) < 1e-9)
        let spread = try plan(Fixture.workout(session(minutes: 120), sets: [timed("s1", 15, 25), timed("s0", 10, 20)]))
        // 10 before, 15 of sets, 10 of the 95 after
        #expect(abs((spread.samples.first?.value ?? 0) - kilocalories(minutes: 35)) < 1e-9)
    }

    @Test func timesOutsideTheSessionAreClampedToIt() throws {
        // One set an hour before the start and one an hour after the end, in a 30-minute session.
        let sets = [timed("s0", -60, -50), timed("s1", 90, 100)]
        let draft = try plan(Fixture.workout(session(minutes: 30), sets: sets))
        // Both become moments at the edges: 10 of the 30 minutes between them count.
        #expect(abs((draft.samples.first?.value ?? 0) - kilocalories(minutes: 10)) < 1e-9)
    }

    @Test func aLongSingleSetCountsInFull() throws {
        let draft = try plan(Fixture.workout(session(minutes: 40), sets: [timed("s0", 0, 35)]))
        // 35 minutes of set and five after it.
        #expect(abs((draft.samples.first?.value ?? 0) - kilocalories(minutes: 40)) < 1e-9)
    }

    @Test func activeTimeIsCappedToo() throws {
        // Back-to-back sets for five hours.
        let sets = (0..<5).map { timed("s\($0)", Double($0) * 60, Double($0 + 1) * 60) }
        let draft = try plan(Fixture.workout(session(minutes: 300), sets: sets))
        #expect(abs((draft.samples.first?.value ?? 0) - kilocalories(minutes: 180)) < 1e-9)
    }

    @Test func theBoundsAreTheDocumentedOnes() {
        #expect(HealthMapper.maxIdleGap == 600)
        #expect(HealthMapper.maxEnergyDuration == 10_800)
    }
}

/// A session can reach Health long after it happened, so its energy uses the weight the user had at the time.
@Suite("Workout energy: which weight")
struct WorkoutEnergyWeightTests {
    private func day(_ offset: Double) -> Date { Fixture.t0.addingTimeInterval(offset * 86_400) }

    private func energy(_ h: Harness) async throws -> Double? {
        let base = HealthSyncIdentifier.base(entity: .workout, entityID: "w1")
        return await h.writer.object(.activeEnergy, base: base)?.value
    }

    @Test func theLastWeightOnOrBeforeTheSessionDayIsUsed() async throws {
        let h = Harness()
        try await h.addWeight(Fixture.weight("b1", kilograms: 90, at: day(-30)))
        try await h.addWeight(Fixture.weight("b2", kilograms: 85, at: day(-2)))
        try await h.addWeight(Fixture.weight("b3", kilograms: 70, at: day(40)))
        try await h.completeSession(Fixture.session("w1", minutes: 60))
        _ = try await h.exporter.drain()
        #expect(try await energy(h) == 4 * 85, "not the latest weight (70 kg), which the user only reached later")
    }

    @Test func aWeightLoggedLaterThatDayCounts() async throws {
        let h = Harness()
        try await h.addWeight(Fixture.weight("b1", kilograms: 90, at: day(-5)))
        try await h.addWeight(Fixture.weight("b2", kilograms: 85, at: Fixture.t0.addingTimeInterval(1800)))
        try await h.completeSession(Fixture.session("w1", minutes: 10))
        _ = try await h.exporter.drain()
        let value = try #require(try await energy(h))
        #expect(abs(value - 4 * 85 * 10 / 60) < 1e-9)
    }

    @Test func withoutAnEarlierWeightTheFirstOneAfterIsUsed() async throws {
        let h = Harness()
        try await h.addWeight(Fixture.weight("b1", kilograms: 80, at: day(10)))
        try await h.addWeight(Fixture.weight("b2", kilograms: 70, at: day(40)))
        try await h.completeSession(Fixture.session("w1", minutes: 60))
        _ = try await h.exporter.drain()
        #expect(try await energy(h) == 4 * 80, "the closest weight in time, not the newest")
    }

    @Test func withNoWeightAtAllThereIsNoEnergy() async throws {
        let h = Harness()
        try await h.completeSession(Fixture.session("w1", minutes: 60))
        _ = try await h.exporter.drain()
        #expect(try await energy(h) == nil)
        #expect(await h.writer.object(.workout, base: HealthSyncIdentifier.base(entity: .workout, entityID: "w1")) != nil)
    }
}

/// What the exporter does with sessions that have nothing to export.
@Suite("Workout export: empty sessions")
struct EmptySessionExportTests {
    @Test func aCompletedSessionWithoutSetsIsNotExportedAndCompletesQuietly() async throws {
        let h = Harness()
        try await h.completeWorkout(Fixture.workout(Fixture.session("w1", minutes: 30), sets: []))
        let report = try await h.exporter.drain()

        #expect(report.synced == 1 && report.failed == 0)
        #expect(await h.writer.plans.isEmpty)
        #expect(await h.writer.objects.isEmpty)
        let row = try #require(await h.exports.row(.workout, "w1"))
        #expect(row.status == .synced && row.healthUUID == HealthExporter.noObjectUUID)
    }

    @Test func aZeroLengthSessionIsNotExported() async throws {
        let h = Harness()
        try await h.completeWorkout(Fixture.workout(Fixture.session("w1", minutes: 0)))
        let report = try await h.exporter.drain()
        #expect(report.synced == 1)
        #expect(await h.writer.objects.isEmpty)
    }

    @Test func aSessionThatLaterLosesItsSetsTakesItsWorkoutOutOfHealth() async throws {
        let h = Harness()
        let session = Fixture.session("w1", minutes: 30)
        try await h.addWeight(Fixture.weight())
        try await h.completeWorkout(Fixture.workout(session))
        _ = try await h.exporter.drain()
        #expect(await h.writer.objects.count == 3, "body mass, workout and energy")

        try await h.completeWorkout(Fixture.workout(session, sets: []))
        _ = try await h.exporter.drain()
        #expect(await h.writer.objects.count == 1, "only the body mass remains")
        #expect(await h.workouts.healthUUIDs["w1"] == .some(nil))
    }
}
