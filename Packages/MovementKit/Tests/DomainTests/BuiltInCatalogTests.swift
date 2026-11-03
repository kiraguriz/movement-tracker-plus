import Foundation
import Testing
@testable import Domain

@Suite("Built-in catalog")
struct BuiltInCatalogTests {
    /// `Packages/MovementKit/Sources/MotionCore/Specs`, found from this file's own path. Domain does not depend on
    /// MotionCore, so the bundled spec files are checked by path.
    private static func specFile(_ specID: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appending(path: "Sources/MotionCore/Specs/\(specID).json", directoryHint: .notDirectory)
    }

    @Test("ids are unique")
    func uniqueIDs() {
        let ids = BuiltInCatalog.exercises.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("every camera exercise names a bundled spec file")
    func specFilesExist() {
        let camera = BuiltInCatalog.exercises.filter(\.supportsCameraTracking)
        #expect(camera.count >= 3)
        for exercise in camera {
            let specID = exercise.specID ?? ""
            #expect(FileManager.default.fileExists(atPath: Self.specFile(specID).path), "\(exercise.id.rawValue): \(specID)")
        }
    }

    @Test("the jumping jack is a bodyweight cardio camera exercise and is experimental")
    func jumpingJack() throws {
        let exercise = try #require(BuiltInCatalog.exercises.first { $0.id == BuiltInCatalog.jumpingJack })
        #expect(exercise.id == "jumpingjack" && exercise.specID == "jumpingjack")
        #expect(exercise.category == .cardio && exercise.equipment == .bodyweight)
        #expect(exercise.primaryMuscles == [.shoulders, .calves, .quadriceps])
        #expect(BuiltInCatalog.experimental == [BuiltInCatalog.jumpingJack])
        #expect(!BuiltInCatalog.experimental.contains(BuiltInCatalog.squatBodyweight))
        #expect(!BuiltInCatalog.experimental.contains(BuiltInCatalog.pushup))
    }
}
