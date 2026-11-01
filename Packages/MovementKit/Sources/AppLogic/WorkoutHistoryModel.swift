import Domain
import Foundation
import Observation

public struct ExerciseProgressPoint: Equatable, Sendable, Identifiable {
    public let day: LocalDay
    public let reps: Int
    public let maximumLoad: Mass?
    public var id: String { day.string }

    /// Only the selected exercise's actual sets enter its trend, never whole-session totals.
    public static func summarize(_ sets: [SetHistoryItem]) -> [ExerciseProgressPoint] {
        Dictionary(grouping: sets, by: \.localDay).map { day, items in
            ExerciseProgressPoint(day: day, reps: items.reduce(0) { $0 + ($1.set.reps ?? 0) },
                maximumLoad: items.compactMap(\.set.load).max { $0.kilograms < $1.kilograms })
        }.sorted { $0.day.string < $1.day.string }
    }
}

@MainActor @Observable
public final class WorkoutHistoryModel {
    public private(set) var summaries: [WorkoutSummary] = []
    public private(set) var progress: [ExerciseProgressPoint] = []
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    public var errorMessage: String?
    public var exerciseID: ExerciseID?
    @ObservationIgnored private let workouts: any WorkoutStore
    @ObservationIgnored private var limit = 50

    public init(workouts: any WorkoutStore) { self.workouts = workouts }

    public func refresh(reset: Bool = false) async {
        if reset { limit = 50 }
        let requestedExercise = exerciseID
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await workouts.history(WorkoutHistoryQuery(exerciseID: requestedExercise, limit: limit + 1))
            let sets: [SetHistoryItem]
            if let requestedExercise { sets = try await workouts.recentSets(exerciseID: requestedExercise, limit: 1000) }
            else { sets = [] }
            try Task.checkCancellation()
            guard requestedExercise == exerciseID else { return }
            summaries = Array(rows.prefix(limit))
            hasMore = rows.count > limit
            progress = ExerciseProgressPoint.summarize(sets)
            errorMessage = nil
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    public func loadMore() async {
        guard !isLoading, hasMore else { return }
        limit += 50
        await refresh()
    }

    public func delete(id: EntityID) async {
        do { try await workouts.deleteSession(id: id); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }
}
