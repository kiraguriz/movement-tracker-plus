import Foundation
import Testing

@testable import CoachKit

/// The offline review words every cue the motion engine can raise. CoachKit does not depend on MotionCore, so the
/// bundled spec files are read by path: a cue added to a spec without a sentence here fails this test, instead of
/// reaching the user as a words-from-the-key guess.
struct OfflineCueTests {
    private struct SpecFile: Decodable {
        struct Rule: Decodable {
            var id: String
            var cue: String?
        }

        var id: String
        var rules: [Rule]
    }

    /// `Packages/MovementKit/Sources/MotionCore/Specs`, found from this file's own path.
    private static func specsDirectory() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.appending(path: "Sources/MotionCore/Specs", directoryHint: .isDirectory)
    }

    private static func specs() throws -> [(file: String, spec: SpecFile)] {
        let directory = specsDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try files.map { ($0.lastPathComponent, try JSONDecoder().decode(SpecFile.self, from: Data(contentsOf: $0))) }
    }

    @Test func everyBundledSpecCueHasAnOfflineSentenceInBothLanguages() throws {
        let specs = try Self.specs()
        // A moved directory must not turn this into a test of nothing.
        try #require(specs.count >= 2, "no spec files found in \(Self.specsDirectory().path)")

        let strings = BuiltInOfflineStrings()
        var checked = 0
        for (file, spec) in specs {
            for rule in spec.rules {
                guard let cue = rule.cue else { continue }
                checked += 1
                for locale in [CoachLocale.en, .zhHans] {
                    let sentence = strings.cueText(forKey: cue, locale: locale)
                    #expect(sentence?.isEmpty == false, "\(file): rule \(rule.id) cue \(cue) has no \(locale) sentence")
                }
            }
        }
        #expect(checked >= 6, "expected the squat and push-up cues, found \(checked)")
    }

    @Test func offlineCueSentencesDifferByLanguage() {
        let strings = BuiltInOfflineStrings()
        for cue in ["cue.squat.deeper", "cue.pushup.lower", "cue.pushup.hipsLevel", "cue.pushup.lockOut"] {
            #expect(strings.cueText(forKey: cue, locale: .en) != strings.cueText(forKey: cue, locale: .zhHans))
        }
    }

    @Test func sessionFallbackUsesSingularAndPluralCounts() {
        let strings = BuiltInOfflineStrings()
        #expect(strings.text(.sessionHeadline(sets: 1, reps: 1), locale: .en) == "1 set, 1 rep")
        #expect(strings.text(.sessionHeadline(sets: 2, reps: 10), locale: .en) == "2 sets, 10 reps")
        #expect(strings.text(.sessionSummary(exercises: 1, sets: 1, reps: 1), locale: .en).hasPrefix("1 exercise, 1 set, 1 rep."))
        #expect(strings.text(.sessionSummary(exercises: 2, sets: 2, reps: 10), locale: .en).hasPrefix("2 exercises, 2 sets, 10 reps."))
        #expect(strings.text(.sessionHeadline(sets: 1, reps: 1), locale: .zhHans) == "1 组，共 1 次")
    }
}
