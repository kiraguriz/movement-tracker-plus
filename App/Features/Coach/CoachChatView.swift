import Domain
import SwiftUI

/// The messages of the open chat, the reply being written, and the composer. A consent card comes first while
/// sharing with Muse is off, and the composer is not offered then.
struct CoachChatView: View {
    @Bindable var model: CoachModel
    let environment: AppEnvironment
    let unitSystem: UnitSystem
    let openTrain: () -> Void

    @FocusState private var isComposing: Bool
    @State private var isPinned = true

    private let bottomID = "coach.bottom"

    private var shownMessages: [ChatMessage] {
        model.messages.filter { $0.role == .user || $0.role == .assistant }
    }

    private var isEmpty: Bool { shownMessages.isEmpty && model.streaming == nil }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    StubBadge()
                    if model.consent.isOn == false {
                        CoachConsentCard(consent: model.consent)
                    }
                    if isEmpty {
                        if model.hasLoaded, model.consent.isOn == true { emptyState }
                    } else {
                        ForEach(shownMessages) { message in
                            CoachMessageRow(
                                message: message, model: model, environment: environment,
                                unitSystem: unitSystem, openTrain: openTrain
                            )
                            .id(message.id)
                        }
                        if let turn = model.streaming {
                            CoachStreamingRow(turn: turn)
                        }
                    }
                    Color.clear.frame(height: 1).id(bottomID)
                }
                .padding(16)
            }
            .defaultScrollAnchor(isEmpty ? .top : .bottom)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 120
            } action: { _, nearBottom in
                isPinned = nearBottom
            }
            .onChange(of: model.streaming) { scrollToBottom(proxy) }
            .onChange(of: model.messages.count) { scrollToBottom(proxy) }
            .onChange(of: model.activeMessageID) {
                // A new turn starts at the bottom whatever the scroll position was.
                isPinned = true
                scrollToBottom(proxy)
            }
            .testIdentifier(AccessibilityID.coachMessages)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.consent.isOn == true { composer }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard isPinned else { return }
        proxy.scrollTo(bottomID, anchor: .bottom)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ask about your training and food", systemImage: "sparkles")
                .font(.headline)
            FlowLayout(spacing: 8) {
                ForEach(Array(CoachSuggestion.allCases.enumerated()), id: \.element) { index, suggestion in
                    Button {
                        model.send(String(localized: suggestion.text), unitSystem: unitSystem)
                    } label: {
                        Text(suggestion.text)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(minHeight: 44)
                            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.coachSuggestion(index))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($isComposing)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                .accessibilityIdentifier(AccessibilityID.coachComposer)
            if model.isSending {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.largeTitle)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Stop")
                .accessibilityIdentifier(AccessibilityID.coachStop)
            } else {
                Button {
                    isPinned = true
                    model.send(unitSystem: unitSystem)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.largeTitle)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .disabled(!model.canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier(AccessibilityID.coachSend)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Questions the empty chat offers. One tap sends it.
private enum CoachSuggestion: CaseIterable {
    case lastWorkout, plan, goal, protein

    var text: LocalizedStringResource {
        switch self {
        case .lastWorkout: "How did my last workout go?"
        case .plan: "Plan my training week"
        case .goal: "Should I change my goal?"
        case .protein: "Am I eating enough protein?"
        }
    }
}
