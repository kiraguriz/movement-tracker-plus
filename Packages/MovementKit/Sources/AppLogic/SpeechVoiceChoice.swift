import Foundation

/// How good an installed text-to-speech voice sounds. The system ships only `standard` voices; `enhanced` and
/// `premium` are downloads the user chooses in Settings, so which ones exist depends on the phone.
public enum SpeechVoiceQuality: Int, Comparable, Sendable {
    case standard = 1
    case enhanced = 2
    case premium = 3

    public static func < (lhs: SpeechVoiceQuality, rhs: SpeechVoiceQuality) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the app needs to know about one installed voice to choose between them. The platform layer builds these
/// from `AVSpeechSynthesisVoice`; the choice itself has no platform dependency.
public struct SpeechVoiceCandidate: Equatable, Sendable {
    public var identifier: String
    /// A BCP 47 tag such as `en-US` or `zh-CN`.
    public var language: String
    public var quality: SpeechVoiceQuality
    /// A novelty voice (Bubbles, Zarvox, ...) or a voice the user trained on their own speech.
    public var isNoveltyOrPersonal: Bool

    public init(identifier: String, language: String, quality: SpeechVoiceQuality, isNoveltyOrPersonal: Bool = false) {
        self.identifier = identifier
        self.language = language
        self.quality = quality
        self.isNoveltyOrPersonal = isNoveltyOrPersonal
    }
}

public enum SpeechVoiceChoice {
    /// The voice to speak `language` with: among the installed voices for exactly that language, the best
    /// quality (premium, then enhanced, then standard). Novelty and personal voices are never chosen. Of equally
    /// good voices the system's default for the language wins (`systemDefaultIdentifier`), then the identifier
    /// order, so the choice is the same on every call. Nil when no voice qualifies; the caller then asks the system
    /// for its default.
    public static func best(
        for language: String, among candidates: [SpeechVoiceCandidate], systemDefaultIdentifier: String? = nil
    ) -> SpeechVoiceCandidate? {
        let wanted = normalized(language)
        let usable = candidates.filter { !$0.isNoveltyOrPersonal && normalized($0.language) == wanted }
        guard let top = usable.map(\.quality).max() else { return nil }
        let best = usable.filter { $0.quality == top }
        if let systemDefaultIdentifier, let preferred = best.first(where: { $0.identifier == systemDefaultIdentifier }) {
            return preferred
        }
        return best.min { $0.identifier < $1.identifier }
    }

    /// `en_US`, `EN-us` and `en-US` are the same language tag.
    private static func normalized(_ tag: String) -> String {
        tag.replacingOccurrences(of: "_", with: "-").lowercased()
    }
}
