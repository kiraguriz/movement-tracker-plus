import CoachKit
import Domain
import SwiftUI

/// The numbers of the set that just ended, then Muse's reading of them when the user has asked for it.
struct SetReviewView: View {
    let model: SetReviewModel
    let units: UnitFormatter
    let onNextSet: () -> Void
    let onFinish: () -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        numbers.frame(minWidth: 320, maxWidth: .infinity)
                        coach.frame(minWidth: 320, maxWidth: .infinity)
                    }
                    VStack(spacing: 20) {
                        numbers
                        coach
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(ExerciseNames.name(of: model.subject.exercise))
            .navigationSubtitle("Set \(model.subject.setNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close, action: onClose)
                        .accessibilityIdentifier(AccessibilityID.reviewClose)
                }
            }
            .safeAreaInset(edge: .bottom) { actions }
        }
        .task { model.start() }
        .onDisappear { model.cancel() }
        .testIdentifier(AccessibilityID.setReview)
    }

    // MARK: On-device numbers

    private var numbers: some View {
        VStack(spacing: 16) {
            StatTileGrid(minimum: 140) {
                StatTile(title: "Reps", value: "\(model.set.reps ?? 0)", identifier: AccessibilityID.reviewReps)
                StatTile(title: "Partial", value: "\(model.set.partialReps)", identifier: AccessibilityID.reviewPartials)
                StatTile(title: "Score", value: scoreText, identifier: AccessibilityID.reviewScore)
                StatTile(title: "Velocity loss", value: velocityLossText, identifier: AccessibilityID.reviewVelocityLoss)
            }
            repChips
            if let rep = model.reps.first(where: { $0.index == model.selectedRep }) {
                RepDetail(rep: rep)
            }
        }
    }

    private var scoreText: String {
        model.set.averageScore.map { Int($0.rounded()).formatted() } ?? "–"
    }

    private var velocityLossText: String {
        model.set.velocityLoss.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–"
    }

    @ScaledMetric(relativeTo: .headline) private var chipMinimum = 60.0

    private var repChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: chipMinimum), spacing: 8)], spacing: 8) {
            ForEach(model.reps) { rep in
                RepChip(rep: rep, isSelected: model.selectedRep == rep.index) {
                    model.selectedRep = model.selectedRep == rep.index ? nil : rep.index
                }
            }
        }
    }

    // MARK: Muse

    @ViewBuilder
    private var coach: some View {
        switch model.muse {
        case .off:
            EmptyView()
        case .streaming(let partial, _):
            MuseCard(content: .streaming(partial), images: [], model: model)
        case .finished(let result):
            MuseCard(content: .finished(result), images: model.sentImages, model: model)
        case .failed(let message):
            MuseCard(content: .failed(message), images: [], model: model)
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { nextSetButton; finishButton }
            VStack(spacing: 12) { finishButton; nextSetButton }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var nextSetButton: some View {
        Button(action: onNextSet) {
            Text("Next set")
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier(AccessibilityID.reviewNextSet)
    }

    private var finishButton: some View {
        Button(action: onFinish) {
            Text("Finish")
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 36)
        }
        .buttonStyle(.glassProminent)
        .accessibilityIdentifier(AccessibilityID.reviewFinish)
    }
}

// MARK: - Reps

private extension RepEntry {
    var hasMajorIssue: Bool { measurement.issues.contains { $0.severity == .major } }
    var hasIssue: Bool { !measurement.issues.isEmpty }

    var tint: Color {
        if hasMajorIssue { .red } else if hasIssue { .orange } else { .green }
    }
}

/// One counted rep: its number and score, coloured by the worst issue it has.
private struct RepChip: View {
    let rep: RepEntry
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(rep.index, format: .number)
                    .font(.headline)
                    .monospacedDigit()
                Text(rep.measurement.score, format: .number)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(rep.tint.opacity(0.18), in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? rep.tint : .clear, lineWidth: 2)
            }
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rep \(rep.index)")
        .accessibilityValue(value)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(AccessibilityID.reviewRep(rep.index))
    }

    private var value: String {
        let issues = rep.measurement.issues.map { LiveText.cue($0.cue ?? $0.ruleID) }
        let score = String(localized: "Score \(rep.measurement.score)")
        return ([score] + issues).joined(separator: ", ")
    }
}

/// Tempo and issues of the selected rep.
private struct RepDetail: View {
    let rep: RepEntry

    var body: some View {
        let measurement = rep.measurement
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Label(seconds(measurement.eccentricMilliseconds), systemImage: "arrow.down")
                Label(seconds(measurement.concentricMilliseconds), systemImage: "arrow.up")
                Spacer(minLength: 0)
                Text("Rep \(rep.index)")
                    .font(.headline)
            }
            .font(.subheadline.monospacedDigit())
            ForEach(measurement.issues, id: \.self) { issue in
                Label {
                    Text(LiveText.cue(issue.cue ?? issue.ruleID))
                } icon: {
                    Image(systemName: issue.severity == .major ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .major ? Color.red : Color.orange)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
    }

    private func seconds(_ milliseconds: Double) -> String {
        Measurement(value: milliseconds / 1000, unit: UnitDuration.seconds).formatted(
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(1)))
        )
    }
}

// MARK: - Muse

private struct MuseCard: View {
    enum Content {
        case streaming(SetReview.Partial)
        case finished(InsightResult<SetReview>)
        case failed(String)
    }

    let content: Content
    let images: [SkeletonImage]
    let model: SetReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            switch content {
            case .streaming(let partial):
                if let headline = partial.headline, !headline.isEmpty {
                    headlineText(headline)
                }
                points(partial.wentWell)
                fixes(partial.fixNext.map { ($0.cue ?? "", $0.why ?? "", $0.repRefs) })
            case .finished(let result):
                if result.origin == .offline { offlineNotice }
                headlineText(result.output.headline)
                points(result.output.wentWell)
                fixes(result.output.fixNext.map { ($0.cue, $0.why, $0.repRefs) })
                nextSet(result.output.nextSet)
                safety(result.output.safetyFlag)
                if result.origin == .muse, let saw = result.whatMuseSaw {
                    WhatMuseSawView(saw: saw, images: images)
                }
            case .failed(let message):
                notice(message)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .testIdentifier(AccessibilityID.reviewMuse)
    }

    private var header: some View {
        MuseHeader(isWorking: model.isMuseRunning)
    }

    private func headlineText(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(AccessibilityID.reviewHeadline)
    }

    @ViewBuilder
    private func points(_ items: [String]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            Label {
                Text(item)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
    }

    @ViewBuilder
    private func fixes(_ items: [(cue: String, why: String, reps: [Int])]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            if !item.cue.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text(item.cue).fontWeight(.semibold)
                    } icon: {
                        Image(systemName: "arrow.turn.down.right").foregroundStyle(.orange)
                    }
                    if !item.why.isEmpty {
                        Text(item.why)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if !item.reps.isEmpty {
                        Text("Reps \(item.reps.map(String.init).joined(separator: ", "))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func nextSet(_ next: SetReview.NextSet) -> some View {
        let parts = [
            String(localized: "\(next.reps) reps"),
            String(localized: "rest \(next.restSec) s"),
            next.tempo,
        ]
        return Label(parts.joined(separator: " · "), systemImage: "forward.fill")
            .font(.subheadline)
    }

    @ViewBuilder
    private func safety(_ flag: SetReview.SafetyFlag) -> some View {
        if flag.level != .none, !flag.note.isEmpty {
            Label(flag.note, systemImage: flag.level == .stop ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(flag.level == .stop ? Color.red : Color.orange)
                .font(.subheadline.weight(.semibold))
        }
    }

    private var offlineNotice: some View {
        MuseNotice(message: nil, retryIdentifier: AccessibilityID.reviewRetry) { model.retry() }
    }

    private func notice(_ message: String) -> some View {
        MuseNotice(message: message, retryIdentifier: AccessibilityID.reviewRetry) { model.retry() }
    }
}

/// The "Muse" title of a card, with a spinner while it is writing.
struct MuseHeader: View {
    let isWorking: Bool

    var body: some View {
        HStack(spacing: 8) {
            Label("Muse", systemImage: "sparkles")
                .font(.headline)
            if isWorking {
                ProgressView()
            }
        }
    }
}

/// Muse could not answer: say so, and offer another go. Without a message the review on screen is the
/// on-device one.
struct MuseNotice: View {
    let message: String?
    let retryIdentifier: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message ?? String(localized: "Muse could not be reached. This was written on your device."), systemImage: "wifi.slash")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try again", action: retry)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .accessibilityIdentifier(retryIdentifier)
        }
    }
}

/// The data that left the phone and the pictures that went with it.
struct WhatMuseSawView: View {
    let saw: WhatMuseSaw
    let images: [SkeletonImage]

    var body: some View {
        DisclosureGroup("What Muse saw") {
            VStack(alignment: .leading, spacing: 12) {
                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                                if let picture = UIImage(data: image.png) {
                                    Image(uiImage: picture)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(height: 140)
                                        .clipShape(.rect(cornerRadius: 12))
                                        .accessibilityLabel(image.summary)
                                }
                            }
                        }
                    }
                }
                Text(saw.input.canonicalString)
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 8)
        }
        .accessibilityIdentifier(AccessibilityID.reviewSaw)
    }
}
