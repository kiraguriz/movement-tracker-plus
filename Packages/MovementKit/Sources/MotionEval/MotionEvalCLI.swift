import Foundation
import PoseCapture

/// The command-line front end. Output goes through closures so tests can capture it.
enum MotionEvalCLI {
    static func run(
        arguments: [String],
        standardOutput: (String) -> Void = { print($0) },
        standardError: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) async -> Int32 {
        let parsed: EvalArguments
        do {
            parsed = try EvalArguments.parse(arguments)
        } catch {
            standardError("motion-eval: \(error.localizedDescription)")
            standardError("")
            standardError(EvalArguments.usage)
            return 2
        }
        if parsed.help {
            standardOutput(EvalArguments.usage)
            return 0
        }

        var failures: [EvalFailure] = []
        var sections: [String] = []

        if !parsed.paths.isEmpty {
            let expanded = EvalRunner.expand(parsed.paths)
            failures.append(contentsOf: expanded.failures)
            let outcome = await EvalRunner.evaluate(
                urls: expanded.urls, specOverride: parsed.specOverride, maxFrameRate: parsed.maxFrameRate
            )
            failures.append(contentsOf: outcome.failures)
            if !outcome.rows.isEmpty {
                let latency = outcome.videoLatencies.isEmpty ? nil : LatencySummary(samples: outcome.videoLatencies)
                sections.append("## Recordings\n\n" + EvalReport.markdown(rows: outcome.rows, videoLatency: latency))
            }
        }

        if parsed.synthetic {
            do {
                let rows = try EvalRunner.evaluateSynthetic()
                sections.append("## Synthetic benchmark\n\n" + EvalReport.markdown(rows: rows, videoLatency: nil))
            } catch {
                failures.append(EvalFailure(name: "synthetic", reason: error.localizedDescription))
            }
        }

        if !sections.isEmpty { standardOutput(sections.joined(separator: "\n\n")) }
        for failure in failures { standardError("motion-eval: \(failure.name): \(failure.reason)") }
        return failures.isEmpty ? 0 : 1
    }
}
