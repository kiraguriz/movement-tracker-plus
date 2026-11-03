import Foundation
import Domain

/// Somewhere the app goes when a request comes from outside the current screen: a link, a notification, an intent,
/// or another tab's button. Links are outside input, so `init?(url:)` accepts only the exact forms `url` produces.
public enum AppRoute: Hashable, Sendable {
    case today
    case train
    case eat
    case me
    case coach
    /// Train with this exercise in the workout (one is started when none is open) and its set started.
    case startSet(ExerciseID)
}

extension AppRoute {
    public static let scheme = "movementtracker"

    /// `movementtracker://today`, `…://train`, `…://train/start?exercise=<slug>`, `…://eat`, `…://me`, `…://coach`.
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil, let host = parts.host?.lowercased() else { return nil }
        let path = parts.path
        let items = parts.queryItems ?? []
        switch (host, path) {
        case ("today", ""), ("eat", ""), ("me", ""), ("coach", ""), ("train", ""):
            guard items.isEmpty else { return nil }
            switch host {
            case "today": self = .today
            case "eat": self = .eat
            case "me": self = .me
            case "coach": self = .coach
            default: self = .train
            }
        case ("train", "/start"):
            guard items.count == 1, let item = items.first, item.name == "exercise",
                  let slug = item.value, Self.isSlug(slug) else { return nil }
            self = .startSet(ExerciseID(slug))
        default:
            return nil
        }
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        switch self {
        case .today: parts.host = "today"
        case .train: parts.host = "train"
        case .eat: parts.host = "eat"
        case .me: parts.host = "me"
        case .coach: parts.host = "coach"
        case .startSet(let id):
            parts.host = "train"
            parts.path = "/start"
            parts.queryItems = [URLQueryItem(name: "exercise", value: id.rawValue)]
        }
        return parts.url!
    }

    /// Exercise slugs are short lowercase dotted words (`squat.bodyweight`, `pushup`, taught ids alike).
    static func isSlug(_ value: String) -> Bool {
        guard (1...64).contains(value.count), value.first != ".", value.last != ".", !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "_" }
    }
}
