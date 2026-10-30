import Foundation
import Testing
@testable import MotionCore

/// Partial reps among full reps, counted from noisy synthetic clips. A push-up that stops at 120 degrees
/// (44 % of the range from the bottom) and a squat that stops at 53 % are partials: neither counted, because
/// noise carried them across the 30 % line, nor missed, because noise kept them above the line where a
/// descent begins. Both used to go wrong on a few seeds of a 200-seed sweep, and not on the few seeds the
/// benchmark clips use, so the sweep is wider than they are.
@Suite("Partial reps under Vision-like noise")
struct PartialRepSweepTests {
    @Test("two partials among eight reps are counted exactly on 60 noise seeds",
          arguments: ["squat 8 and 2 partials", "push-up 8 and 2 partials"])
    func exact(name: String) throws {
        let clip = try #require(VelocityClip.all.first { $0.name == name })
        var wrong: [String] = []
        for seed in UInt64(1)...60 {
            let summary = try run(clip.motion(seed: seed)).summary
            if summary.reps != 8 || summary.partials != 2 || summary.rejected != 0 {
                wrong.append("seed \(seed): \(summary.reps) reps, \(summary.partials) partials, \(summary.rejected) rejected")
            }
        }
        #expect(wrong.isEmpty, "\(wrong.joined(separator: "; "))")
    }
}
