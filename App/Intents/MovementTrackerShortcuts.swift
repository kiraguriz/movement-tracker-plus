import AppIntents

/// The phrases Siri and Spotlight know without the user setting anything up. Their translations are in
/// `AppShortcuts.xcstrings`.
nonisolated struct MovementTrackerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSetIntent(),
            phrases: [
                "Start a set of \(\.$exercise) in \(.applicationName)",
                "Start \(\.$exercise) in \(.applicationName)",
            ],
            shortTitle: "Start a set",
            systemImageName: "figure.strengthtraining.traditional"
        )
        AppShortcut(
            intent: LogWeightIntent(),
            phrases: [
                "Log weight in \(.applicationName)",
                "Log my weight in \(.applicationName)",
            ],
            shortTitle: "Log weight",
            systemImageName: "scalemass"
        )
    }
}
