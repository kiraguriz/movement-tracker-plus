import Domain
import Foundation
import Persistence
import Testing
@testable import AppLogic

@Suite("Taught exercises")
struct TaughtExerciseTests {
    // MARK: Names

    @Test("a name is cleaned of line breaks, controls and extra white space")
    func cleaning() {
        #expect(TaughtExercise.cleanName("  Walking \n\n Lunge\t") == "Walking Lunge")
        #expect(TaughtExercise.cleanName("Lunge\u{0007}\u{200B}s") == "Lunges")
        #expect(TaughtExercise.cleanName("\n \t") == "")
        #expect(TaughtExercise.cleanName("深蹲  变式") == "深蹲 变式")
    }

    @Test("two to forty characters are a name")
    func validation() {
        #expect(TaughtExercise.validate("") == .failure(.tooShort))
        #expect(TaughtExercise.validate(" a ") == .failure(.tooShort))
        #expect(TaughtExercise.validate("ab") == .success("ab"))
        #expect(TaughtExercise.validate("深蹲") == .success("深蹲"))
        #expect(TaughtExercise.validate(String(repeating: "x", count: 40)) == .success(String(repeating: "x", count: 40)))
        #expect(TaughtExercise.validate(String(repeating: "x", count: 41)) == .failure(.tooLong))
    }

    @Test("an existing name is found whatever its case and punctuation")
    func existing() {
        let catalog = BuiltInCatalog.exercises + [Exercise(id: "taught.lunge.aaaaaa", name: "Reverse Lunge", specID: "taught.lunge.aaaaaa")]
        #expect(TaughtExercise.existing(named: "push up", in: catalog)?.id == BuiltInCatalog.pushup)
        #expect(TaughtExercise.existing(named: "PUSH-UP", in: catalog)?.id == BuiltInCatalog.pushup)
        #expect(TaughtExercise.existing(named: "reverse lunge", in: catalog)?.id == "taught.lunge.aaaaaa")
        #expect(TaughtExercise.existing(named: "Lunge", in: catalog) == nil)
        #expect(TaughtExercise.existing(named: "Squat jump", in: catalog) == nil, "a longer name is a different exercise")
        #expect(TaughtExercise.existing(named: "俯卧撑", in: catalog, displayName: { $0.id == BuiltInCatalog.pushup ? "俯卧撑" : $0.name })?.id == BuiltInCatalog.pushup)
        #expect(TaughtExercise.existing(named: "", in: catalog) == nil)
    }

    // MARK: Ids

    @Test("ids are readable slugs with a random tail")
    func ids() {
        #expect(TaughtExercise.makeID(name: "Walking Lunge", randomness: 0xABCDEF).rawValue == "taught.walking-lunge.abcdef")
        #expect(TaughtExercise.makeID(name: "  Hammer   Curl!! ", randomness: 1).rawValue == "taught.hammer-curl.000001")
        #expect(TaughtExercise.makeID(name: "深蹲变式", randomness: 0x123456).rawValue == "taught.exercise.123456")
        #expect(TaughtExercise.makeID(name: "💪🏽", randomness: 0xFFFF_FFFF).rawValue == "taught.exercise.ffffff")
        #expect(TaughtExercise.makeID(name: "Café Raise", randomness: 2).rawValue == "taught.caf-raise.000002")
        let long = TaughtExercise.makeID(name: String(repeating: "abc ", count: 10), randomness: 3).rawValue
        #expect(long.count <= "taught.".count + 24 + 7)
        #expect(!long.contains("-."))
    }

    @Test("the same name taught twice gives two different ids")
    func uniqueness() {
        var seen = Set<ExerciseID>()
        for random in UInt64(0)..<200 { seen.insert(TaughtExercise.makeID(name: "Lunge", randomness: random &* 0x9E37_79B9)) }
        #expect(seen.count == 200)
        #expect(seen.allSatisfy(TaughtExercise.isTaught))
        #expect(!TaughtExercise.isTaught(BuiltInCatalog.pushup))
    }

    // MARK: Which spec counts

    private func stored(_ id: String, version: Int, origin: SpecOrigin, at seconds: Double = 0) -> StoredExerciseSpec {
        StoredExerciseSpec(
            id: EntityID(id), exerciseID: "taught.x.000000", version: version, origin: origin,
            json: JSONPayload(json: "{}"), createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("the highest version comes first, a Muse spec before a taught one of the same version")
    func candidateOrder() {
        let specs = [
            stored("a", version: 1, origin: .taught, at: 10),
            stored("b", version: 2, origin: .taught, at: 20),
            stored("c", version: 2, origin: .muse, at: 5),
            stored("d", version: 3, origin: .taught, at: 1),
            stored("e", version: 2, origin: .muse, at: 30),
        ]
        #expect(SpecCandidates.ordered(specs).map(\.id.rawValue) == ["d", "e", "c", "b", "a"])
        #expect(SpecCandidates.ordered([]).isEmpty)
        #expect(SpecCandidates.ordered(specs.reversed()).map(\.id.rawValue) == ["d", "e", "c", "b", "a"])
    }

    // MARK: Saving

    @Test("saving stores the exercise and its taught spec as version one")
    func saves() async throws {
        let database = try AppDatabase.inMemory()
        let saver = TaughtExerciseSaver(store: database.exercises)
        let exercise = Exercise(
            id: "taught.lunge.abcdef", name: "Lunge", primaryMuscles: [.quadriceps, .glutes], equipment: .bodyweight,
            specID: "taught.lunge.abcdef"
        )
        let json = JSONPayload(json: #"{"id":"taught.lunge.abcdef"}"#)
        let row = try await saver.save(exercise: exercise, specJSON: json, specRowID: "spec-1", now: Date(timeIntervalSince1970: 100))
        #expect(row.version == 1 && row.origin == .taught)
        #expect(try await database.exercises.exercise(id: exercise.id) == exercise)
        #expect(try await database.exercises.specs(for: exercise.id) == [row])
    }

    @Test("saving again never collides with the row that is there")
    func savesAgain() async throws {
        let database = try AppDatabase.inMemory()
        let saver = TaughtExerciseSaver(store: database.exercises)
        let exercise = Exercise(id: "taught.lunge.abcdef", name: "Lunge", specID: "taught.lunge.abcdef")
        let json = JSONPayload(json: "{}")
        let first = try await saver.save(exercise: exercise, specJSON: json, specRowID: "spec-1", now: Date(timeIntervalSince1970: 100))
        let second = try await saver.save(exercise: exercise, specJSON: json, specRowID: "spec-2", now: Date(timeIntervalSince1970: 200))
        #expect(first.version == 1 && second.version == 2)
        #expect(SpecCandidates.ordered(try await database.exercises.specs(for: exercise.id)).first?.id == "spec-2")
    }

    @Test("a spec that cannot be stored takes the new exercise back")
    func rollsBack() async throws {
        let database = try AppDatabase.inMemory()
        let saver = TaughtExerciseSaver(store: database.exercises)
        let exercise = Exercise(id: "taught.lunge.abcdef", name: "Lunge", specID: "taught.lunge.abcdef")
        await #expect(throws: (any Error).self) {
            try await saver.save(exercise: exercise, specJSON: JSONPayload(json: "{nope"), specRowID: "spec-1", now: Date())
        }
        #expect(try await database.exercises.exercise(id: exercise.id) == nil)
    }

    @Test("a failure on a second teaching leaves the first exercise alone")
    func rollbackKeepsExisting() async throws {
        let database = try AppDatabase.inMemory()
        let saver = TaughtExerciseSaver(store: database.exercises)
        let exercise = Exercise(id: "taught.lunge.abcdef", name: "Lunge", specID: "taught.lunge.abcdef")
        try await saver.save(exercise: exercise, specJSON: JSONPayload(json: "{}"), specRowID: "spec-1", now: Date())
        await #expect(throws: (any Error).self) {
            try await saver.save(exercise: exercise, specJSON: JSONPayload(json: "{nope"), specRowID: "spec-2", now: Date())
        }
        #expect(try await database.exercises.exercise(id: exercise.id) != nil)
        #expect(try await database.exercises.specs(for: exercise.id).count == 1)
    }

    @Test("a taught exercise is found by search and supports the camera")
    func searchable() async throws {
        let database = try AppDatabase.inMemory()
        let saver = TaughtExerciseSaver(store: database.exercises)
        let exercise = Exercise(id: "taught.lunge.abcdef", name: "Lunge", primaryMuscles: [.quadriceps], specID: "taught.lunge.abcdef")
        try await saver.save(exercise: exercise, specJSON: JSONPayload(json: "{}"), specRowID: "spec-1", now: Date())
        let found = try await database.exercises.search("lun", limit: 5)
        #expect(found.map(\.id) == [exercise.id] && found[0].supportsCameraTracking)
    }
}
