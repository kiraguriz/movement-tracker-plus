import Foundation
import PoseCapture

/// One evaluated clip.
struct EvalRow: Equatable {
    var name: String
    var exercise: String
    var expectedReps: Int?
    var expectedPartials: Int?
    var counted: Int
    var partials: Int
    var meanScore: Double?
    var velocityLoss: Double?

    /// Counted minus expected; nil when the clip has no expected count.
    var error: Int? { expectedReps.map { counted - $0 } }
    /// An idle clip expects no reps at all.
    var isIdle: Bool { expectedReps == 0 }
}

/// Accuracy over a set of rows. Only rows with an expected rep count take part in the rates.
struct EvalSummary: Equatable {
    var clips = 0
    var labelled = 0
    var exact = 0
    /// Within one rep of the truth (the "off-by-one accuracy" of the repetition-counting literature).
    var withinOne = 0
    var meanAbsoluteError = 0.0
    var idleClips = 0
    var falseReps = 0
    var partialsLabelled = 0
    var partialsExact = 0

    init(rows: [EvalRow]) {
        clips = rows.count
        let labelledRows = rows.filter { $0.error != nil }
        labelled = labelledRows.count
        exact = labelledRows.filter { $0.error == 0 }.count
        withinOne = labelledRows.filter { abs($0.error ?? 0) <= 1 }.count
        if !labelledRows.isEmpty {
            meanAbsoluteError = Double(labelledRows.reduce(0) { $0 + abs($1.error ?? 0) }) / Double(labelledRows.count)
        }
        let idle = rows.filter(\.isIdle)
        idleClips = idle.count
        falseReps = idle.reduce(0) { $0 + $1.counted }
        let partialRows = rows.filter { $0.expectedPartials != nil }
        partialsLabelled = partialRows.count
        partialsExact = partialRows.filter { $0.partials == $0.expectedPartials }.count
    }
}

/// Formats the table and the summary as Markdown.
enum EvalReport {
    static let headers = ["File", "Exercise", "Expected", "Counted", "Partials", "Error", "Mean score", "Velocity loss"]

    static func markdown(rows: [EvalRow], videoLatency: LatencySummary?) -> String {
        var lines: [String] = []
        lines.append(table(rows: rows))
        lines.append("")
        lines.append(contentsOf: summaryLines(EvalSummary(rows: rows), videoLatency: videoLatency))
        return lines.joined(separator: "\n")
    }

    static func table(rows: [EvalRow]) -> String {
        let body = rows.map(cells(for:))
        return renderTable(headers: headers, rightAligned: Set(2...7), rows: body)
    }

    static func cells(for row: EvalRow) -> [String] {
        [
            row.name,
            row.exercise,
            row.expectedReps.map(String.init) ?? "–",
            String(row.counted),
            partialsCell(for: row),
            row.error.map { $0 == 0 ? "0" : String(format: "%+d", $0) } ?? "–",
            row.meanScore.map { String(format: "%.1f", $0) } ?? "–",
            row.velocityLoss.map { String(format: "%.0f%%", $0 * 100) } ?? "–",
        ]
    }

    /// The partial-rep count, or "counted ≠ expected" when the clip says how many there should be and it differs.
    static func partialsCell(for row: EvalRow) -> String {
        guard let expected = row.expectedPartials, expected != row.partials else { return String(row.partials) }
        return "\(row.partials) ≠ \(expected)"
    }

    static func summaryLines(_ s: EvalSummary, videoLatency: LatencySummary?) -> [String] {
        func rate(_ n: Int, _ d: Int) -> String {
            d == 0 ? "–" : String(format: "%d/%d (%.0f%%)", n, d, Double(n) / Double(d) * 100)
        }
        var lines = ["**Summary** — \(s.clips) clip\(s.clips == 1 ? "" : "s"), \(s.labelled) with an expected count", ""]
        lines.append("- Exact count: \(rate(s.exact, s.labelled))")
        lines.append("- Off-by-one accuracy (within ±1 rep): \(rate(s.withinOne, s.labelled))")
        lines.append("- Mean absolute error: \(s.labelled == 0 ? "–" : String(format: "%.2f reps", s.meanAbsoluteError))")
        lines.append("- False reps on idle clips: \(s.idleClips == 0 ? "no idle clips" : "\(s.falseReps) over \(s.idleClips) idle clip\(s.idleClips == 1 ? "" : "s")")")
        if s.partialsLabelled > 0 {
            lines.append("- Partial reps exact: \(rate(s.partialsExact, s.partialsLabelled))")
        }
        if let latency = videoLatency, latency.count > 0 {
            lines.append(String(
                format: "- Vision latency on this Mac (%d video frames): p50 %.1f ms, p95 %.1f ms, mean %.1f ms",
                latency.count, latency.p50 * 1000, latency.p95 * 1000, latency.mean * 1000
            ))
        }
        return lines
    }

    /// A Markdown table with columns padded to equal width, so it reads well as plain text too.
    static func renderTable(headers: [String], rightAligned: Set<Int>, rows: [[String]]) -> String {
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }
        let escaped = rows.map { $0.map(escape) }
        var widths = headers.map(\.count)
        for row in escaped {
            for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.count) }
        }
        func pad(_ text: String, _ column: Int) -> String {
            let gap = String(repeating: " ", count: max(0, widths[column] - text.count))
            return rightAligned.contains(column) ? gap + text : text + gap
        }
        func line(_ cells: [String]) -> String {
            "| " + cells.enumerated().map { pad($0.element, $0.offset) }.joined(separator: " | ") + " |"
        }
        let rule = "| " + widths.enumerated().map { column, width in
            rightAligned.contains(column)
                ? String(repeating: "-", count: max(2, width) - 1) + ":"
                : String(repeating: "-", count: max(3, width))
        }.joined(separator: " | ") + " |"
        return ([line(headers), rule] + escaped.map(line)).joined(separator: "\n")
    }
}
