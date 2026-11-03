import Domain
import Foundation

/// The bookkeeping around exercises the user taught the app: their names, ids, which stored spec counts and
/// how one is saved. The spec itself (MotionCore) is not seen here; Domain stores it as JSON.
public enum TaughtExercise {
    public static let minNameLength = 2
    public static let maxNameLength = 40

    public enum NameProblem: Error, Equatable, Sendable {
        case tooShort
        case tooLong
    }

    /// The name as it is stored: control characters and line breaks gone, runs of white space made one space,
    /// no white space at either end.
    public static func cleanName(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .lineSeparator
                || scalar.properties.generalCategory == .paragraphSeparator {
                scalars.append(" ")
            } else if scalar.properties.generalCategory != .control, scalar.properties.generalCategory != .format {
                scalars.append(scalar)
            }
        }
        return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    public static func validate(_ raw: String) -> Result<String, NameProblem> {
        let name = cleanName(raw)
        if name.count < minNameLength { return .failure(.tooShort) }
        if name.count > maxNameLength { return .failure(.tooLong) }
        return .success(name)
    }

    /// Lower-case ASCII letters and digits of a name joined by hyphens, at most 24 characters; `exercise` when
    /// the name has none (a name in Chinese, an emoji).
    public static func slug(_ name: String) -> String {
        var slug = ""
        var pendingSeparator = false
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.append(character)
            } else {
                pendingSeparator = true
            }
        }
        slug = String(slug.prefix(24))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "exercise" : slug
    }

    /// `taught.<slug>.<six hex digits>`: unique per teaching, also for two exercises of one name, and valid as
    /// the MotionCore spec id.
    public static func makeID(name: String, randomness: UInt64) -> ExerciseID {
        let suffix = String(format: "%06x", Int(randomness & 0xFF_FFFF))
        return ExerciseID("taught.\(slug(name)).\(suffix)")
    }

    public static func isTaught(_ id: ExerciseID) -> Bool {
        id.rawValue.hasPrefix("taught.")
    }

    /// The exercise that already has this name, ignoring case, spaces and punctuation. `displayName` adds the
    /// names the user sees (the built-ins are translated).
    public static func existing(named name: String, in catalog: [Exercise], displayName: (Exercise) -> String = { $0.name }) -> Exercise? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        return catalog.first { normalize($0.name) == wanted || normalize(displayName($0)) == wanted }
    }

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.map(Character.init))
    }
}

/// Which stored spec of an exercise counts. A built-in spec (bundled with the app) is looked up before any of
/// these; among the stored ones the highest version wins, a Muse-authored version before a taught one of the
/// same version, and the app falls back to the next candidate when one cannot be loaded.
public enum SpecCandidates {
    public static func ordered(_ specs: [StoredExerciseSpec]) -> [StoredExerciseSpec] {
        specs.sorted { lhs, rhs in
            if lhs.version != rhs.version { return lhs.version > rhs.version }
            if rank(lhs.origin) != rank(rhs.origin) { return rank(lhs.origin) > rank(rhs.origin) }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id > rhs.id
        }
    }

    private static func rank(_ origin: SpecOrigin) -> Int {
        switch origin {
        case .muse: 2
        case .taught: 1
        case .builtin: 0
        }
    }
}

/// Saves a taught exercise: the exercise row, then its spec. A failure on the second step takes the first
/// back, so there is never an exercise that claims a camera spec it does not have.
public struct TaughtExerciseSaver: Sendable {
    private let store: any ExerciseCatalogStore

    public init(store: any ExerciseCatalogStore) {
        self.store = store
    }

    /// `specJSON` is the encoded MotionCore spec. The row version is the next free one for this exercise and
    /// origin, so saving again (a re-teach) never collides with an earlier row.
    @discardableResult
    public func save(
        exercise: Exercise, specJSON: JSONPayload, origin: SpecOrigin = .taught, specRowID: EntityID, now: Date
    ) async throws -> StoredExerciseSpec {
        let existed = try await store.exercise(id: exercise.id) != nil
        try await store.save(exercise)
        do {
            let version = try await store.specs(for: exercise.id).filter { $0.origin == origin }.map(\.version).max().map { $0 + 1 } ?? 1
            let row = StoredExerciseSpec(
                id: specRowID, exerciseID: exercise.id, version: version, origin: origin, json: specJSON, createdAt: now
            )
            try await store.save(row)
            return row
        } catch {
            if !existed { try? await store.deleteExercise(id: exercise.id) }
            throw error
        }
    }
}
