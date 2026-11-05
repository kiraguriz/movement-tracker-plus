import CoachKit
import Domain
import SwiftUI

// MARK: - Text

extension AttributedString {
    /// Assistant text with inline Markdown (bold, italics, code) and its own line breaks kept. Text that is not
    /// valid Markdown, or is cut mid-marker while streaming, shows as written.
    init(coachText text: String) {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        self = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        // Links in a model reply stay plain text, so a reply cannot send the user anywhere.
        for run in runs where run.link != nil { self[run.range].link = nil }
    }
}

// MARK: - Rows

/// One stored message: the user's bubble with its send status, or the coach's text with its tools and proposals.
struct CoachMessageRow: View {
    let message: ChatMessage
    let model: CoachModel
    let environment: AppEnvironment
    let unitSystem: UnitSystem
    let openTrain: (() -> Void)?

    var body: some View {
        switch message.role {
        case .user: userRow
        case .assistant: assistantRow
        case .tool, .system: EmptyView()
        }
    }

    // MARK: User

    private var isUnsent: Bool { message.status != .sent && model.activeMessageID != message.id }

    private var userRow: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(message.content)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(TraceTheme.night, in: UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, bottomTrailingRadius: 6, topTrailingRadius: 22))
                .opacity(message.status == .sent || model.activeMessageID == message.id ? 1 : 0.7)
                .frame(maxWidth: 560, alignment: .trailing)
                .textSelection(.enabled)
                .accessibilityIdentifier(AccessibilityID.coachUserMessage)
            if isUnsent {
                VStack(alignment: .trailing, spacing: 2) {
                    Label("Not sent", systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.red)
                    if let failure = model.failures[message.id] {
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Try Again") { model.retry(message, unitSystem: unitSystem) }
                        .buttonStyle(.bordered)
                        .disabled(model.isSending || model.consent.isOn != true || model.failures[message.id].map { !$0.isRetryable } == true)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier(AccessibilityID.coachRetry)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityID.coachFailed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Assistant

    private var assistantRow: some View {
        let metadata = message.coachMetadata
        return VStack(alignment: .leading, spacing: 10) {
            if let looked = metadata?.looked, !looked.isEmpty {
                ToolChips(runs: looked, isRunning: false)
            }
            if !message.content.isEmpty {
                Text(AttributedString(coachText: message.content))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityID.coachAssistantMessage)
            }
            ForEach(metadata?.proposals ?? []) { proposal in
                ProposalCard(proposal: proposal, message: message, model: model, environment: environment, units: UnitFormatter(system: unitSystem), openTrain: openTrain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The reply that is still being written.
struct CoachStreamingRow: View {
    let turn: StreamingTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if turn.text.isEmpty {
                ProgressView()
                    .frame(minHeight: 24)
                    .accessibilityLabel("Thinking")
            } else {
                Text(AttributedString(coachText: turn.text))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(AccessibilityID.coachStreaming)
            }
            let looked = turn.runs.filter(\.isRead)
            if !looked.isEmpty || !turn.running.isEmpty {
                ToolChips(runs: looked, isRunning: !turn.running.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Tool chips

/// What the coach looked at, one chip per read tool that succeeded.
struct ToolChips: View {
    let runs: [ToolRun]
    let isRunning: Bool

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(runs) { run in
                ToolChip(run: run)
            }
            if isRunning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking your data")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(TraceTheme.blue.opacity(0.1), in: .capsule)
            }
        }
    }
}

struct ToolChip: View {
    let run: ToolRun

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(TraceTheme.blue)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(TraceTheme.card, in: .capsule)
        .overlay { Capsule().strokeBorder(TraceTheme.line, lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Coach looked at \(title)"))
        .accessibilityIdentifier(AccessibilityID.coachToolChip)
    }

    private var title: String {
        let count = run.count
        return switch run.subject {
        case .sessions: count == 0 ? String(localized: "No sessions") : String(localized: "\(count) sessions")
        case .setDetail: count == 0 ? String(localized: "Set not found") : String(localized: "One set")
        case .nutritionDay: count == 0 ? String(localized: "No meals logged") : String(localized: "\(count) meals")
        case .bodyTrend: count == 0 ? String(localized: "No measurements") : String(localized: "\(count) measurements")
        case .goal: count == 0 ? String(localized: "No goal set") : String(localized: "Your goal")
        case .plan, .mealLog, .goalChange, nil: run.name
        }
    }

    private var symbol: String {
        switch run.subject {
        case .sessions: "figure.strengthtraining.traditional"
        case .setDetail: "list.number"
        case .nutritionDay: "fork.knife"
        case .bodyTrend: "scalemass"
        case .goal: "target"
        case .plan, .mealLog, .goalChange, nil: "wrench.and.screwdriver"
        }
    }
}

// MARK: - Flow layout

/// Lays its children out in rows, wrapping to the next row when a child does not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: ProposedViewSize(result.sizes[index])
            )
        }
    }

    /// Items wrap to the next row when they do not fit, and an item wider than a row wraps its own text.
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint], sizes: [CGSize]) {
        var origins: [CGPoint] = []
        var sizes: [CGSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            sizes.append(size)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins, sizes)
    }
}
