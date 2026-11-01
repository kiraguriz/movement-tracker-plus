import AppLogic
import Domain
import SwiftUI

// MARK: - Extension points for the Eat tab
//
// The Eat tab opens one sheet per way of adding a meal: the manual form, food search (`FoodSearchSheet`, USDA
// through the proxy) and the meal photo (`MealPhotoSheet`, a Muse estimate then a USDA lookup). A sheet gets an
// `EatAddContext` and finishes by calling `context.log(...)`, which writes the meals and the foods they use in one
// transaction and updates every screen through the observation streams.

/// The ways to add a meal.
enum EatAddRoute: String, CaseIterable, Identifiable {
    case manual
    case search
    case photo

    var id: String { rawValue }

    /// The routes the add menu can offer.
    static let available: [EatAddRoute] = [.manual, .search, .photo]

    /// The routes to offer in this app. Search and photo go through the coach's proxy, so without one the menu
    /// offers manual entry only.
    static func offered(in environment: AppEnvironment) -> [EatAddRoute] {
        environment.coach == nil ? [.manual] : available
    }

    var title: LocalizedStringResource {
        switch self {
        case .manual: "Manual entry"
        case .search: "Search food"
        case .photo: "Meal photo"
        }
    }

    var systemImage: String {
        switch self {
        case .manual: "square.and.pencil"
        case .search: "magnifyingglass"
        case .photo: "camera"
        }
    }
}

/// What an add-meal sheet needs: where the meal goes, a way to save it, and the app's ports.
struct EatAddContext {
    var day: LocalDay
    var suggestedSlot: MealSlot
    var environment: AppEnvironment
    /// Saves meals and the foods they reference in one transaction. Throws when the write fails.
    var log: ([MealEntry], [Food]) async throws -> Void
}

/// The sheet for an add route.
struct EatAddDestination: View {
    let route: EatAddRoute
    let context: EatAddContext
    let onSaved: () -> Void

    var body: some View {
        switch route {
        case .manual:
            MealEditorSheet(draft: MealDraft(slot: context.suggestedSlot), day: context.day, environment: context.environment) { meal in
                try await context.log([meal], [])
                onSaved()
            }
        case .search:
            FoodSearchSheet(context: context, onSaved: onSaved)
        case .photo:
            MealPhotoSheet(context: context, onSaved: onSaved)
        }
    }
}
