import CoachKit
import Domain
import Foundation
import SwiftUI

extension CoachLocale {
    /// The language the app shows, for the coach's answers.
    static var app: CoachLocale {
        CoachLocale(identifier: Bundle.main.preferredLocalizations.first ?? Locale.current.identifier)
    }
}

// MARK: - Failures

/// A failed coach or food call, as the screens show it. `CoachError.errorDescription` is English only, so every case
/// is mapped to a localized sentence here.
struct CoachFailure: Equatable {
    enum Area {
        case chat, search, photo
    }

    enum Kind {
        case budget, offline, paused, busy, unavailable, refused, other
    }

    var kind: Kind
    var message: String
    /// True when asking again later can work. CoachKit knows which failures that holds for (a spent budget, a
    /// refusal, a bad request or the proxy's own broken credentials stay as they are); anything else is a
    /// connection problem.
    var isRetryable: Bool

    init(_ error: any Error, area: Area) {
        kind = Self.kind(of: error)
        isRetryable = (error as? CoachError)?.isTransient ?? true
        message = Self.message(kind, area: area, isRetryable: isRetryable)
    }

    private static func kind(of error: any Error) -> Kind {
        if error is URLError { return .offline }
        guard let error = error as? CoachError else { return .other }
        switch error {
        case .budgetExhausted: return .budget
        case .network: return .offline
        case .servicePaused: return .paused
        case .rateLimited: return .busy
        case .unavailable: return .unavailable
        case .upstream(let status, _, _): return status >= 500 ? .unavailable : .other
        case .refused: return .refused
        case .invalidInput, .badRequest, .payloadTooLarge, .unauthorized, .failed, .streamEnded, .incomplete, .emptyOutput,
             .malformedOutput, .toolLoopLimit, .malformedResponse:
            return .other
        }
    }

    private static func message(_ kind: Kind, area: Area, isRetryable: Bool) -> String {
        switch (kind, area) {
        case (.budget, .chat): String(localized: "You've reached today's coach limit. Try again tomorrow.")
        case (.budget, .search): String(localized: "You've reached today's search limit. You can still add meals by hand.")
        case (.budget, .photo): String(localized: "You've reached today's photo limit. You can still add meals by hand.")
        case (.offline, _): String(localized: "You're offline. Check your connection and try again.")
        case (.paused, .search): String(localized: "Food search is paused right now. Try again later.")
        case (.paused, _): String(localized: "The coach is paused right now. Try again later.")
        case (.busy, .search): String(localized: "Food search is busy. Try again in a moment.")
        case (.busy, _): String(localized: "The coach is busy. Try again in a moment.")
        case (.unavailable, .search): String(localized: "Food search is unavailable right now. Try again later.")
        case (.unavailable, _): String(localized: "The coach is unavailable right now. Try again later.")
        case (.refused, _): String(localized: "The coach can't help with that.")
        case (.other, _) where isRetryable: String(localized: "That didn't work. Try again.")
        case (.other, _): String(localized: "That didn't work.")
        }
    }
}

// MARK: - Consent

/// Whether the user allowed data to go to Muse (`SettingKey.aiOptIn`). Every Muse call checks it first: CoachKit does
/// not. Food search is USDA, not Muse, and does not need it.
@Observable
final class AIConsent {
    /// Nil until the stored value has been read.
    private(set) var isOn: Bool?
    var errorMessage: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    /// Follows the setting until the surrounding task is cancelled (the Me tab's toggle changes it too).
    func run() async {
        await environment.settings.observe(SettingKey.aiOptIn).forEachValue(
            onFailure: { errorMessage = $0.localizedDescription },
            { isOn = $0 }
        )
    }

    func set(_ isOn: Bool) {
        let previous = self.isOn
        self.isOn = isOn
        Task {
            do {
                try await environment.settings.set(SettingKey.aiOptIn, to: isOn)
            } catch {
                // The store still holds the old value, and a Muse call reads the store: show what is true.
                self.isOn = previous
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The stored value, read now: the check that comes right before a Muse call.
    func isGranted() async -> Bool {
        await environment.isAIOptedIn()
    }
}

extension AppEnvironment {
    /// Whether the user allowed data to go to Muse, read from the store now. A failed read counts as no. The one
    /// check behind every Muse call: the coach chat, the meal photo and the Train flow.
    func isAIOptedIn() async -> Bool {
        (try? await settings.get(SettingKey.aiOptIn)) ?? false
    }
}

// MARK: - Debug marker

/// Shown on every screen that is backed by the Debug stub, so canned answers never pass for Muse.
struct StubBadge: View {
    @Environment(\.appEnvironment) private var environment

    var body: some View {
        #if DEBUG
        if environment.coachIsStub {
            Label("Stub data, not Muse", systemImage: "wrench.and.screwdriver")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.2), in: .capsule)
                .foregroundStyle(.orange)
                .accessibilityIdentifier(AccessibilityID.stubBadge)
        }
        #else
        EmptyView()
        #endif
    }
}
