import AppLogic
import Domain
import SwiftUI

/// The words for Today's suggestion. Domain says which facts applied; the sentences are written here so they can be
/// localized.
enum TodayPlanText {
    static func bucketName(_ bucket: MuscleBucket) -> String {
        switch bucket {
        case .lower: String(localized: "bucket.lower")
        case .push: String(localized: "bucket.push")
        case .pull: String(localized: "bucket.pull")
        case .core: String(localized: "bucket.core")
        }
    }

    static func bandName(_ band: ReadinessBand) -> String {
        switch band {
        case .ready: String(localized: "readiness.band.ready")
        case .steady: String(localized: "readiness.band.steady")
        case .easy: String(localized: "readiness.band.easy")
        }
    }

    static func reason(_ reason: TodayReason) -> String {
        switch reason {
        case .firstSession: String(localized: "A gentle first session")
        case .rested(.lower): String(localized: "Legs rested")
        case .rested(.push): String(localized: "Push muscles rested")
        case .rested(.pull): String(localized: "Pull muscles rested")
        case .rested(.core): String(localized: "Core rested")
        case .progress: String(localized: "Last time went well: add a rep")
        case .weekDone: String(localized: "This week's target is done")
        case .notRecovered: String(localized: "Muscles still recovering")
        case .loadHigh: String(localized: "A lot of training lately")
        case .sleepShort: String(localized: "Short night")
        case .hrvBelow: String(localized: "HRV below your usual")
        case .restingHeartRateAbove: String(localized: "Resting heart rate above your usual")
        case .todayDone: String(localized: "You already trained today")
        }
    }

    /// At most two reasons on one line.
    static func reasons(_ reasons: [TodayReason]) -> String {
        reasons.prefix(2).map(reason).joined(separator: " · ")
    }

    static func accessibilityReadiness(_ readiness: ReadinessResult) -> String {
        let band = bandName(readiness.band)
        if let score = readiness.score { return String(localized: "Readiness \(score), \(band)") }
        return String(localized: "Readiness, \(band)")
    }

    static func doneSummary(sets: Int, reps: Int) -> String {
        "\(String(localized: "\(sets) sets")) · \(String(localized: "\(reps) reps"))"
    }
}
