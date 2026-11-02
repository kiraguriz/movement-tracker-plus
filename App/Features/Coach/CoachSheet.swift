import Domain
import SwiftUI

/// The coach: a chat with on-device tools. Proposals in the chat change data only after a tap on their card.
struct CoachSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(UserSession.self) private var session
    @State private var model: CoachModel
    @State private var isShowingThreads = false

    private let environment: AppEnvironment
    private let openTrain: () -> Void

    init(environment: AppEnvironment, openTrain: @escaping () -> Void) {
        self.environment = environment
        self.openTrain = openTrain
        _model = State(initialValue: CoachModel(environment: environment))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(model.thread?.title ?? String(localized: "Coach"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                            .accessibilityIdentifier(AccessibilityID.coachClose)
                    }
                    if environment.coachChat != nil {
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button {
                                isShowingThreads = true
                            } label: {
                                Label("Chats", systemImage: "clock.arrow.circlepath")
                            }
                            .labelStyle(.iconOnly)
                            .disabled(model.isSending || model.threads.isEmpty)
                            .accessibilityIdentifier(AccessibilityID.coachHistory)
                            Button {
                                model.newChat()
                            } label: {
                                Label("New chat", systemImage: "square.and.pencil")
                            }
                            .labelStyle(.iconOnly)
                            .disabled(model.isSending || (model.thread == nil && model.messages.isEmpty))
                            .accessibilityIdentifier(AccessibilityID.coachNewChat)
                        }
                    }
                }
                .errorAlert($model.errorMessage)
        }
        .tint(TraceTheme.blue)
        .presentationBackground(TraceTheme.paper)
        .presentationDragIndicator(.visible)
        .task { await model.run() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $isShowingThreads) { CoachThreadList(model: model) }
        .testIdentifier(AccessibilityID.coachSheet)
    }

    @ViewBuilder
    private var content: some View {
        if environment.coachChat == nil {
            ContentUnavailableView("Coach is unavailable", systemImage: "sparkles")
                .accessibilityIdentifier(AccessibilityID.coachUnavailable)
        } else {
            CoachChatView(
                model: model,
                environment: environment,
                unitSystem: session.unitSystem,
                openTrain: { dismiss(); openTrain() }
            )
        }
    }
}

#Preview {
    SeededPreview { environment in
        CoachSheet(environment: environment, openTrain: {})
    }
}
