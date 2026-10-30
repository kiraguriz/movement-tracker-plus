import CoachKit
import Domain
import Foundation
import MotionCore

/// The one gate every Muse call of the Train flow goes through: the coach must exist (the proxy is known) and
/// the user must have opted in. CoachKit does not check consent itself.
enum TrainCoachAccess {
    static func coach(in environment: AppEnvironment) async -> CoachService? {
        guard let coach = environment.coach else { return nil }
        let optedIn = (try? await environment.settings.get(SettingKey.aiOptIn)) ?? false
        return optedIn ? coach : nil
    }
}

extension CoachLocale {
    /// The language the app is showing, which is the language of spoken cues and of Muse's answers.
    static var app: CoachLocale {
        CoachLocale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }
}

/// Translated sentences for the engine's keys. The keys live in `Localizable.xcstrings` (`cue.*`, `framing.*`).
enum LiveText {
    static func cue(_ key: CueKey) -> String {
        Bundle.main.localizedString(forKey: key.rawValue, value: readable(key.rawValue), table: nil)
    }

    static func cue(_ key: String) -> String {
        cue(CueKey(key))
    }

    static func framing(_ state: FramingState) -> String {
        Bundle.main.localizedString(forKey: state.localizationKey, value: readable(state.localizationKey), table: nil)
    }

    /// "cue.squat.chestUp" becomes "chest up", for a key the catalog does not know yet.
    private static func readable(_ key: String) -> String {
        let tail = key.split(separator: ".").last.map(String.init) ?? key
        var words = ""
        for character in tail {
            if character.isUppercase, !words.isEmpty { words.append(" ") }
            words.append(contentsOf: character.lowercased())
        }
        return words
    }
}

extension FramingState {
    /// The symbol next to a framing prompt.
    var symbolName: String {
        switch self {
        case .noPerson: "person.crop.rectangle"
        case .stepBack: "arrow.down.backward.and.arrow.up.forward"
        case .moveCloser: "arrow.up.forward.and.arrow.down.backward"
        case .wholeBody: "figure.stand"
        case .turnSideways: "figure.turn.right"
        case .faceCamera: "person.fill.viewfinder"
        case .holdStill: "hand.raised"
        case .ready: "checkmark.circle"
        }
    }
}
