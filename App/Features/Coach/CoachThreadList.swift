import Domain
import SwiftUI

/// The earlier chats; choosing one opens it in the Coach sheet.
struct CoachThreadList: View {
    let model: CoachModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.threads) { thread in
                    Button {
                        Task {
                            await model.open(thread)
                            dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(thread.title)
                                .lineLimit(2)
                            Text(thread.updatedAt, format: .relative(presentation: .named))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .foregroundStyle(.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await model.delete(thread) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.coachThread(thread.title))
                }
            }
            .overlay {
                if model.threads.isEmpty {
                    ContentUnavailableView("No chats", systemImage: "bubble.left")
                }
            }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .testIdentifier(AccessibilityID.coachThreads)
    }
}
