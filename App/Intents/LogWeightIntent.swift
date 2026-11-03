import AppIntents
import Domain
import Foundation

/// "Log weight": saves a weight taken now, without opening the app.
struct LogWeightIntent: AppIntent {
    static let title: LocalizedStringResource = "Log weight"

    @Parameter(title: "Weight")
    var weight: Measurement<UnitMass>

    static var parameterSummary: some ParameterSummary {
        Summary("Log weight \(\.$weight)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let kilograms = weight.converted(to: .kilograms).value
        guard GoalPlanner.weightRange.contains(kilograms) else { throw LogWeightError.outOfRange }
        let environment = try await EnvironmentProvider.shared.environment()
        let measurement = BodyMeasurement(
            id: environment.newID(), kind: .weight, value: kilograms,
            measuredAt: environment.now(), timeZone: environment.timeZone(), source: .app
        )
        try await environment.bodyMeasurements.save(measurement)
        return .result(dialog: "Logged")
    }
}

nonisolated enum LogWeightError: Error, CustomLocalizedStringResourceConvertible {
    case outOfRange

    var localizedStringResource: LocalizedStringResource { "That weight doesn't look right." }
}
