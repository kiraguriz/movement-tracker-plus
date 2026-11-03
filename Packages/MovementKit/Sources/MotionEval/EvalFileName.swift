import Foundation
import MotionCore

/// Expected counts and exercise read from a file name such as `squat.bodyweight_10.mov` or
/// `pushup_8_2.mp4`: the exercise, then the true rep count, then optionally the partial-rep count,
/// separated by underscores. Anything after the numbers is ignored (`squat_10_room2_front`).
enum EvalFileName {
    struct Parsed: Equatable {
        var exerciseID: String?
        var reps: Int?
        var partials: Int?
    }

    /// Spellings that name a bundled exercise, lower-cased.
    static let aliases: [String: BundledSpec] = [
        "squat": .squatBodyweight, "squats": .squatBodyweight, "squat.bodyweight": .squatBodyweight,
        "pushup": .pushUp, "pushups": .pushUp, "push-up": .pushUp, "push-ups": .pushUp,
        "jumpingjack": .jumpingJack, "jumpingjacks": .jumpingJack, "jumping-jack": .jumpingJack, "jumping-jacks": .jumpingJack,
    ]

    static func parse(_ fileName: String) -> Parsed {
        let stem = URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        let tokens = stem.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard let exerciseIndex = tokens.firstIndex(where: { aliases[$0.lowercased()] != nil }) else {
            return Parsed()
        }
        var parsed = Parsed(exerciseID: aliases[tokens[exerciseIndex].lowercased()]?.rawValue)
        var numbers: [Int] = []
        for token in tokens[(exerciseIndex + 1)...] {
            guard let n = Int(token), n >= 0 else { break }
            numbers.append(n)
            if numbers.count == 2 { break }
        }
        parsed.reps = numbers.first
        parsed.partials = numbers.count > 1 ? numbers[1] : nil
        return parsed
    }
}
