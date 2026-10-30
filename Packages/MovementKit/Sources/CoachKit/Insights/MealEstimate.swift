import Domain
import Foundation

/// What Muse returns for a meal photo (strict schema `MealEstimate`). The app looks each `usdaQuery` up through the
/// proxy and lets the user edit grams before saving.
public struct MealEstimate: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var name: String
        public var gramsEstimate: Double
        /// 0 to 1.
        public var confidence: Double
        /// An English, generic USDA search phrase.
        public var usdaQuery: String

        public init(name: String, gramsEstimate: Double, confidence: Double, usdaQuery: String) {
            self.name = name
            self.gramsEstimate = gramsEstimate
            self.confidence = confidence
            self.usdaQuery = usdaQuery
        }
    }

    public var items: [Item]
    public var notes: String

    public init(items: [Item], notes: String) {
        self.items = items
        self.notes = notes
    }

    public static let schema: JSONValue = Schema.object([
        "items": Schema.array(
            of: Schema.object([
                "name": Schema.string("What the user will read, in the user's language."),
                "gramsEstimate": Schema.number("Best estimate of the eaten weight in grams."),
                "confidence": Schema.number("0 to 1."),
                "usdaQuery": Schema.string("English, generic USDA FoodData Central search phrase, 2 to 100 characters."),
            ]),
            "Each distinct food in the photo; empty when there is no food."
        ),
        "notes": Schema.string("One or two sentences about the biggest uncertainty."),
    ])

    func validated() throws -> MealEstimate {
        var estimate = self
        estimate.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        estimate.items = try items.prefix(20).enumerated().map { position, item in
            var item = item
            item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            item.usdaQuery = item.usdaQuery.trimmingCharacters(in: .whitespacesAndNewlines).prefix(utf16Limit: 100)
            guard !item.name.isEmpty else { throw CoachError.malformedOutput("items[\(position)].name is empty.") }
            guard item.usdaQuery.utf16.count >= 2 else {
                throw CoachError.malformedOutput("items[\(position)].usdaQuery must be an English search phrase of 2 to 100 characters.")
            }
            guard item.gramsEstimate.isFinite, item.gramsEstimate > 0, item.gramsEstimate <= 3000 else {
                throw CoachError.malformedOutput("items[\(position)].gramsEstimate must be between 1 and 3000 grams.")
            }
            item.gramsEstimate = item.gramsEstimate.rounded()
            item.confidence = item.confidence.isFinite ? min(1, max(0, item.confidence)) : 0
            return item
        }
        return estimate
    }
}

/// A photo of a meal to estimate.
public struct MealPhotoInput: Sendable, Equatable {
    /// JPEG data. Metadata (EXIF, XMP, comments) is removed before it is sent; the orientation is kept.
    public var jpeg: Data
    /// What the estimate is about for the insight store (for example the local day), or nil.
    public var subjectID: String?
    /// Words from the user about the meal ("two eggs and toast"), if any.
    public var note: String?
    public var unitSystem: UnitSystem

    public init(jpeg: Data, subjectID: String? = nil, note: String? = nil, unitSystem: UnitSystem = .metric) {
        self.jpeg = jpeg
        self.subjectID = subjectID
        self.note = note
        self.unitSystem = unitSystem
    }

    var json: JSONValue {
        .compact([
            "task": "Estimate the foods and portions in the attached photo of a meal.",
            "note": note.flatMap(SetReviewInput.cleanNote).map { .string(String($0.prefix(300))) },
            "units": .string(unitSystem.rawValue),
        ])
    }
}
