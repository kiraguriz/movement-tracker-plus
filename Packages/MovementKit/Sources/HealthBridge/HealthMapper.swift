import Domain
import Foundation

public enum HealthMappingError: Error, Equatable, Sendable, LocalizedError {
    case sessionWithoutEnd
    case sessionEndsBeforeStart

    public var errorDescription: String? {
        switch self {
        case .sessionWithoutEnd: "The completed session has no end time."
        case .sessionEndsBeforeStart: "The session ends before it starts."
        }
    }
}

/// Domain entities → write plans. Pure: no clocks, no stores, no HealthKit.
public enum HealthMapper {
    /// MET assumed for a strength session: the 2011 Compendium of Physical Activities lists resistance training from
    /// 3.5 (multiple exercises, 8–15 reps, code 02054) to 6.0 (vigorous effort), with squats at 5.0 (02052). The
    /// sessions here mix bodyweight and loaded sets at unknown effort, so the squat value sits between the extremes.
    /// It is a coarse default, which is why the energy is always written as an estimate.
    public static let strengthTrainingMET = 5.0

    /// One MET is resting energy. Health's active energy excludes it, so the estimate subtracts it.
    static let restingMET = 1.0

    /// The longest stretch between two logged moments of a session (start, sets, end) that still counts as training.
    /// A MET value for resistance training already averages over the pauses between sets, so ordinary rests count in
    /// full; ten minutes covers the longest rest after a heavy set or a change of equipment. Beyond that nobody was
    /// training, which is what a session left open and finished later looks like.
    public static let maxIdleGap: TimeInterval = 10 * 60

    /// No session is credited with more than this many seconds of energy, whatever its length. Strength sessions
    /// rarely pass two hours; this is the bound for sessions whose sets carry no times to tell active from idle.
    public static let maxEnergyDuration: TimeInterval = 3 * 3600

    /// Active energy for a session: (MET − 1) × body mass (kg) × hours. Nil when an input cannot give a positive result.
    public static func estimatedActiveEnergy(
        bodyMass: Mass,
        duration: TimeInterval,
        met: Double = strengthTrainingMET
    ) -> Energy? {
        guard bodyMass.kilograms.isFinite, bodyMass.kilograms > 0,
              duration.isFinite, duration > 0,
              met.isFinite, met > restingMET
        else { return nil }
        return Energy(kilocalories: (met - restingMET) * bodyMass.kilograms * duration / 3600)
    }

    // MARK: Workout

    /// The seconds of `start...end` that count toward the energy estimate.
    ///
    /// When every set carries a time, the set itself counts in full, and each gap before, between and after sets counts
    /// up to `maxIdleGap`. When any set has no time there is nothing to tell active from idle, so the elapsed time counts.
    /// Either way the result never exceeds `maxEnergyDuration`.
    static func countedDuration(of workout: Workout, from start: Date, to end: Date) -> TimeInterval {
        let elapsed = end.timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        guard let spans = timedSpans(of: workout, from: start, to: end) else { return min(elapsed, maxEnergyDuration) }

        var counted = 0.0
        var cursor = start
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if span.start > cursor { counted += min(span.start.timeIntervalSince(cursor), maxIdleGap) }
            if span.end > cursor {
                counted += span.end.timeIntervalSince(max(span.start, cursor))
                cursor = span.end
            }
        }
        counted += min(end.timeIntervalSince(cursor), maxIdleGap)
        return min(counted, maxEnergyDuration)
    }

    /// Each set's time span clamped to the session, or nil unless every set has at least one time. A set with only one
    /// time is a single moment.
    private static func timedSpans(of workout: Workout, from start: Date, to end: Date) -> [(start: Date, end: Date)]? {
        var spans: [(start: Date, end: Date)] = []
        for logged in workout.exercises.flatMap(\.sets) {
            guard let first = logged.set.startedAt ?? logged.set.endedAt, let last = logged.set.endedAt ?? logged.set.startedAt else {
                return nil
            }
            let (low, high) = (min(first, last), max(first, last))
            spans.append((min(max(low, start), end), min(max(high, start), end)))
        }
        return spans.isEmpty ? nil : spans
    }

    /// A completed session becomes a strength-training workout. The energy sample is skipped when no body mass is known.
    ///
    /// Nothing is exported, and anything an earlier version put into Health is removed, when the session has no sets
    /// (the app refuses to finish such a session, so it is stray data) or lasted no time at all (nothing can be trained
    /// in an empty interval, and Health's workout builder is not documented to accept one). A session that is merely
    /// short is exported with its few seconds of energy. Any status other than completed also yields an empty plan.
    public static func plan(for workout: Workout, export: HealthExport, bodyMass: Mass?) throws -> HealthWritePlan {
        let session = workout.session
        guard session.status == .completed else { return HealthWritePlan(export: export) }
        guard let end = session.endedAt else { throw HealthMappingError.sessionWithoutEnd }
        guard end >= session.startedAt else { throw HealthMappingError.sessionEndsBeforeStart }
        guard end > session.startedAt, workout.setCount > 0 else { return HealthWritePlan(export: export) }

        let zone = resolve(session.timeZoneID)
        let counted = countedDuration(of: workout, from: session.startedAt, to: end)
        var samples: [HealthSampleDraft] = []
        var metadata: [String: HealthMetadataValue] = [:]
        if let bodyMass, let energy = estimatedActiveEnergy(bodyMass: bodyMass, duration: counted) {
            metadata = [
                HealthMetadataKey.energyIsEstimate: .bool(true),
                HealthMetadataKey.energyMethod: .string("MET"),
                HealthMetadataKey.met: .double(strengthTrainingMET),
                HealthMetadataKey.bodyMassKilograms: .double(bodyMass.kilograms),
                HealthMetadataKey.energySeconds: .double(counted),
            ]
            samples.append(sample(.activeEnergy, energy.kilocalories, from: session.startedAt, to: end, zone: zone, export: export, metadata: metadata))
        }
        let draft = HealthWorkoutDraft(
            start: session.startedAt,
            end: end,
            timeZoneID: zone.identifier,
            syncIdentifier: HealthSyncIdentifier.object(.workout, base: export.syncIdentifier),
            syncVersion: export.syncVersion,
            metadata: metadata,
            samples: samples
        )
        return HealthWritePlan(export: export, workout: draft)
    }

    // MARK: Meal

    /// Energy, protein, carbohydrate and fat, each only when known. A known zero is written; an unknown is not.
    public static func plan(for meal: MealEntry, export: HealthExport) -> HealthWritePlan {
        let zone = resolve(meal.timeZoneID)
        let date = healthDate(meal.loggedAt, on: meal.localDay, in: zone)
        let values: [(HealthObjectKind, Double?)] = [
            (.dietaryEnergy, meal.nutrients.energy?.kilocalories),
            (.dietaryProtein, meal.nutrients.protein?.grams),
            (.dietaryCarbohydrate, meal.nutrients.carbohydrate?.grams),
            (.dietaryFat, meal.nutrients.fat?.grams),
        ]
        let samples = values.compactMap { kind, value in
            representable(value).map { sample(kind, $0, from: date, to: date, zone: zone, export: export) }
        }
        return HealthWritePlan(export: export, samples: samples)
    }

    // MARK: Body mass

    /// Only weights the user entered in this app are exported. Health-sourced values came from Health already.
    public static func isExportable(_ measurement: BodyMeasurement) -> Bool {
        measurement.kind == .weight && measurement.source == .app
    }

    public static func plan(for measurement: BodyMeasurement, export: HealthExport) -> HealthWritePlan {
        guard isExportable(measurement), measurement.value.isFinite, measurement.value > 0 else {
            return HealthWritePlan(export: export)
        }
        let zone = resolve(measurement.timeZoneID)
        let date = healthDate(measurement.measuredAt, on: measurement.localDay, in: zone)
        let body = sample(.bodyMass, measurement.value, from: date, to: date, zone: zone, export: export)
        return HealthWritePlan(export: export, samples: [body])
    }

    // MARK: Helpers

    /// The instant to give Health for something that counts toward `day`. A meal can be logged later for an earlier
    /// day, and Health would otherwise file it under the day it was typed in; such an instant is clamped into the day.
    static func healthDate(_ instant: Date, on day: LocalDay, in zone: TimeZone) -> Date {
        let interval = day.interval(in: zone)
        if interval.contains(instant) { return instant }
        return instant < interval.lowerBound ? interval.lowerBound : interval.upperBound.addingTimeInterval(-1)
    }

    static func resolve(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? .gmt
    }

    /// Health rejects negative and non-finite quantities.
    private static func representable(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func sample(
        _ kind: HealthObjectKind,
        _ value: Double,
        from start: Date,
        to end: Date,
        zone: TimeZone,
        export: HealthExport,
        metadata: [String: HealthMetadataValue] = [:]
    ) -> HealthSampleDraft {
        HealthSampleDraft(
            kind: kind,
            value: value,
            start: start,
            end: end,
            timeZoneID: zone.identifier,
            syncIdentifier: HealthSyncIdentifier.object(kind, base: export.syncIdentifier),
            syncVersion: export.syncVersion,
            metadata: metadata
        )
    }
}
