import Foundation

/// The language the coach answers in. The app supports English and Simplified Chinese; JSON keys and enum
/// values in every schema stay English whatever the locale.
public enum CoachLocale: String, Codable, CaseIterable, Sendable {
    case en
    case zhHans = "zh-Hans"

    /// Maps a BCP 47 or `Locale` identifier (`zh-Hans-CN`, `zh_CN`, `en-GB`) to a supported locale.
    /// Any Chinese maps to Simplified; everything else to English.
    public init(identifier: String) {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        self = normalized == "zh" || normalized.hasPrefix("zh-") ? .zhHans : .en
    }

    public init(_ locale: Locale) {
        self.init(identifier: locale.identifier)
    }

    /// How the prompt names the language.
    public var promptLanguageName: String {
        switch self {
        case .en: "English"
        case .zhHans: "Simplified Chinese (简体中文)"
        }
    }

    /// The name Meta's speech-to-text `languageBias` expects.
    public var speechLanguageName: String {
        switch self {
        case .en: "English"
        case .zhHans: "Mandarin Chinese"
        }
    }
}
