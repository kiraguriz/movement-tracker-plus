import Foundation

/// The sentences of the on-device fallback reviews, as data the strings are built from.
public enum OfflineText: Sendable, Equatable {
    case setHeadline(reps: Int, averageScore: Int?)
    case setHeadlineClean(reps: Int)
    case cleanReps([Int])
    case repsCompleted(Int)
    case averageScore(Int)
    /// "Measured on this device in reps 2, 4 of 8."
    case fixWhy(reps: [Int], total: Int)
    case tempo
    case sessionHeadline(sets: Int, reps: Int)
    case sessionSummary(exercises: Int, sets: Int, reps: Int)
    case sessionHighlight(exercise: String, averageScore: Int)
    case sessionConcern(cue: String)
    case sessionFocusRepeat
    case sessionFocusFix(cue: String)
    /// The chat's stand-in when the model, asked to answer without tools, did not.
    case chatNoAnswer
}

/// Words for the offline fallbacks. The built-in table covers English and Simplified Chinese; the app can pass its
/// own (backed by its string catalog) to `CoachService`.
public protocol OfflineStrings: Sendable {
    func text(_ text: OfflineText, locale: CoachLocale) -> String
    /// The sentence for a cue key such as `cue.squat.deeper`, or nil when the table does not know it.
    func cueText(forKey key: String, locale: CoachLocale) -> String?
}

extension OfflineStrings {
    /// The cue sentence, or a readable version of the key's last part ("hipsUp" becomes "hips up").
    func cue(_ key: String, locale: CoachLocale) -> String {
        if let known = cueText(forKey: key, locale: locale) { return known }
        let tail = key.split(separator: ".").last.map(String.init) ?? key
        var words = ""
        for character in tail {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(contentsOf: character.lowercased())
        }
        return words
    }
}

public struct BuiltInOfflineStrings: OfflineStrings {
    public init() {}

    /// One entry for every `cue` of a bundled exercise spec (`MotionCore/Specs/*.json`); `OfflineCueTests`
    /// compares the two, because this module does not depend on MotionCore.
    private static let cues: [String: (en: String, zh: String)] = [
        "cue.squat.deeper": ("Sit deeper: hips to knee height", "再蹲深一点：髋部降到膝盖高度"),
        "cue.squat.chestUp": ("Keep your chest up", "挺胸，保持上身直立"),
        "cue.controlDown": ("Lower slowly and stay in control", "下放时放慢速度，保持控制"),
        "cue.pushup.lower": ("Lower your chest closer to the floor", "胸部再靠近地面一点"),
        "cue.pushup.hipsLevel": ("Keep hips, shoulders and ankles in one line", "保持肩、髋、踝成一条直线"),
        "cue.pushup.lockOut": ("Press all the way up until your arms are straight", "向上推到手臂完全伸直"),
    ]

    public func cueText(forKey key: String, locale: CoachLocale) -> String? {
        guard let entry = Self.cues[key] else { return nil }
        return locale == .zhHans ? entry.zh : entry.en
    }

    public func text(_ text: OfflineText, locale: CoachLocale) -> String {
        switch locale {
        case .en: english(text)
        case .zhHans: chinese(text)
        }
    }

    private func list(_ numbers: [Int], separator: String = ", ") -> String {
        numbers.map(String.init).joined(separator: separator)
    }

    private func english(_ text: OfflineText) -> String {
        switch text {
        case .setHeadline(let reps, let score):
            score.map { "\(reps) reps, average score \($0)" } ?? "\(reps) reps"
        case .setHeadlineClean(let reps): "\(reps) clean reps"
        case .cleanReps(let reps): "Clean reps: \(list(reps))"
        case .repsCompleted(let reps): "You completed \(reps) reps."
        case .averageScore(let score): "Average form score \(score) out of 100."
        case .fixWhy(let reps, let total): "Measured on this device in rep\(reps.count == 1 ? "" : "s") \(list(reps)) of \(total)."
        case .tempo: "3 s down, 1 s up"
        case .sessionHeadline(let sets, let reps): "\(sets) sets, \(reps) reps"
        case .sessionSummary(let exercises, let sets, let reps):
            "\(exercises) exercise\(exercises == 1 ? "" : "s"), \(sets) sets, \(reps) reps. This summary was made on your device from the measured numbers."
        case .sessionHighlight(let exercise, let score): "\(exercise): average form score \(score)."
        case .sessionConcern(let cue): cue
        case .sessionFocusRepeat: "Repeat this session and keep the form steady."
        case .sessionFocusFix(let cue): "Focus: \(cue)"
        case .chatNoAnswer: "I couldn't finish looking into that. Try asking again, or ask about something narrower."
        }
    }

    private func chinese(_ text: OfflineText) -> String {
        switch text {
        case .setHeadline(let reps, let score):
            score.map { "\(reps) 次，平均得分 \($0)" } ?? "\(reps) 次"
        case .setHeadlineClean(let reps): "\(reps) 次动作全部标准"
        case .cleanReps(let reps): "标准的动作：第 \(list(reps, separator: "、")) 次"
        case .repsCompleted(let reps): "你完成了 \(reps) 次。"
        case .averageScore(let score): "动作平均得分 \(score)（满分 100）。"
        case .fixWhy(let reps, let total): "本机测得：共 \(total) 次中的第 \(list(reps, separator: "、")) 次。"
        case .tempo: "下放 3 秒，上推 1 秒"
        case .sessionHeadline(let sets, let reps): "\(sets) 组，共 \(reps) 次"
        case .sessionSummary(let exercises, let sets, let reps):
            "\(exercises) 个动作，\(sets) 组，\(reps) 次。此摘要由你的设备根据测得的数据生成。"
        case .sessionHighlight(let exercise, let score): "\(exercise)：动作平均得分 \(score)。"
        case .sessionConcern(let cue): cue
        case .sessionFocusRepeat: "重复本次训练，保持动作稳定。"
        case .sessionFocusFix(let cue): "重点：\(cue)"
        case .chatNoAnswer: "这个问题我没能查完。请再问一次，或把问题缩小一些。"
        }
    }
}
