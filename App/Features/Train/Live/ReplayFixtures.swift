import Foundation
import MotionCore
import PoseCapture

/// Pose recordings bundled with the app for the Simulator, UI tests and demo rehearsal. They are made by
/// `tools/replay-fixtures` from `SyntheticMotion`; the app only reads them.
enum ReplayFixtures {
    enum LoadError: LocalizedError {
        case missing(String)

        var errorDescription: String? {
            switch self {
            case .missing(let name): String(localized: "The pose recording “\(name)” is not in the app.")
            }
        }
    }

    /// The recording to replay for an exercise when none was asked for by name.
    static func defaultName(forSpecID id: String) -> String {
        switch BundledSpec(rawValue: id) {
        case .pushUp: "pushup"
        case .jumpingJack: "jumpingjack"
        default: "squat"
        }
    }

    nonisolated static func url(named name: String) -> URL? {
        let file = "replay-\(name)"
        return Bundle.main.url(forResource: file, withExtension: "jsonl", subdirectory: "ReplayPoses")
            ?? Bundle.main.url(forResource: file, withExtension: "jsonl")
    }

    /// Reads and decodes the recording off the main actor.
    @concurrent
    static func load(named name: String) async throws -> PoseFixture {
        guard let url = url(named: name) else { throw LoadError.missing(name) }
        return try PoseFixtureFile.read(from: url)
    }
}

/// Where opt-in pose recordings of camera sets are kept.
enum PoseCaptureFiles {
    nonisolated static var archive: PoseRecordingArchive {
        PoseRecordingArchive(
            directory: URL.applicationSupportDirectory
                .appending(path: "MovementTracker", directoryHint: .isDirectory)
                .appending(path: "PoseCaptures", directoryHint: .isDirectory),
            exportDirectory: URL.documentsDirectory.appending(path: "PoseCaptures", directoryHint: .isDirectory)
        )
    }
}
