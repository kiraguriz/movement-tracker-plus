import Domain
import SwiftUI

// MARK: - Extension points for the Eat tab
//
// The Eat tab opens one sheet per way of adding a meal. Today only the manual form exists. Two more are reserved:
//
//   1. FOOD SEARCH  (USDA FoodData Central through the proxy, `GET /v1/food/search`)
//   2. MEAL PHOTO   (Muse estimate, then a USDA lookup, then an editable confirm sheet)
//
// To add one: implement its sheet below, add its case to `EatAddRoute.available`, and nothing else in
// `EatView` changes. A sheet gets an `EatAddContext` and finishes by calling `context.log(...)`, which writes the
// meals and the foods they use in one transaction and updates every screen through the observation streams.
// Do not add networking to this file's callers; the search and photo clients belong to the coach/food client.

/// The ways to add a meal.
enum EatAddRoute: String, CaseIterable, Identifiable {
    case manual
    case search
    case photo

    var id: String { rawValue }

    /// The routes the add menu offers. EXTENSION POINT: append `.search` and `.photo` when their sheets are built.
    static let available: [EatAddRoute] = [.manual]

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

/// EXTENSION POINT 1: food search. Presented for `EatAddRoute.search`.
struct FoodSearchSheet: View {
    let context: EatAddContext

    var body: some View {
        EmptyView()
    }
}

/// EXTENSION POINT 2: meal photo. Presented for `EatAddRoute.photo`.
struct MealPhotoSheet: View {
    let context: EatAddContext

    var body: some View {
        EmptyView()
    }
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
            FoodSearchSheet(context: context)
        case .photo:
            MealPhotoSheet(context: context)
        }
    }
}
