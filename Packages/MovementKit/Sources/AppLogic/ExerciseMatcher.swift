import Domain
import Foundation

/// Finds the catalog exercise a coach-written name means. Plans come back in the user's language, so the built-in
/// exercises also answer to common English variants and Chinese names.
public enum ExerciseMatcher {
    private static let aliases: [ExerciseID: [String]] = [
        BuiltInCatalog.squatBodyweight: ["bodyweight squat", "air squat", "squat", "深蹲", "徒手深蹲", "自重深蹲"],
        BuiltInCatalog.pushup: ["push-up", "push up", "pushup", "俯卧撑"],
        "squat.barbell": ["barbell back squat", "back squat", "barbell squat", "杠铃深蹲"],
        "bench.press": ["bench press", "barbell bench press", "卧推", "杠铃卧推"],
        "deadlift": ["deadlift", "硬拉"],
        "overhead.press": ["overhead press", "shoulder press", "military press", "肩上推举", "推举"],
        "row.barbell": ["barbell row", "bent-over row", "bent over row", "杠铃划船"],
        "pullup": ["pull-up", "pull up", "pullup", "引体向上"],
        "curl.dumbbell": ["dumbbell curl", "biceps curl", "bicep curl", "哑铃弯举"],
        BuiltInCatalog.jumpingJack: ["jumping jack", "jumping jacks", "star jump", "star jumps", "开合跳"],
    ]

    public static func match(_ name: String, in catalog: [Exercise]) -> ExerciseID? {
        let wanted = normalize(name)
        guard !wanted.isEmpty else { return nil }
        if let exact = catalog.first(where: { normalize($0.name) == wanted }) { return exact.id }

        var best: (id: ExerciseID, length: Int)?
        for (id, names) in aliases where catalog.contains(where: { $0.id == id }) {
            for alias in names.map(normalize) {
                if alias == wanted { return id }
                // "Barbell back squat (high bar)" contains "back squat"; short aliases only match whole names.
                if alias.count >= 4, wanted.contains(alias), alias.count > (best?.length ?? 0) { best = (id, alias.count) }
            }
        }
        return best?.id
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased().unicodeScalars.filter { $0.properties.isAlphabetic || $0.properties.numericType != nil }.map(String.init).joined()
    }
}
