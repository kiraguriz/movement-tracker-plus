import Foundation

/// Launch arguments that change how the app starts. They apply to Debug builds only; a Release build ignores them.
///
/// - `-MTInMemoryDatabase`: use a throwaway in-memory database instead of the file in Application Support.
/// - `-MTSeed profile|sample`: with the in-memory database, start with a finished profile (`profile`)
///   or with a profile plus weights, meals and a workout (`sample`).
/// - `-MTStartTab today|train|eat|me`: the tab to show first.
/// - `-MTFailDatabase`: behave as if the database could not be opened.
/// - `-MTCoachURL <url>`: talk to the coach proxy at this address (for example `wrangler dev`) instead of
///   `CoachEndpoint.deployed`.
struct LaunchOptions: Equatable {
    enum Seed: String {
        case none, profile, sample
    }

    var inMemoryDatabase = false
    var seed = Seed.none
    var startTab: String?
    var failDatabase = false
    var coachURL: URL?

    init() {}

    init(arguments: [String]) {
        inMemoryDatabase = arguments.contains("-MTInMemoryDatabase")
        failDatabase = arguments.contains("-MTFailDatabase")
        seed = Self.value(after: "-MTSeed", in: arguments).flatMap(Seed.init(rawValue:)) ?? .none
        startTab = Self.value(after: "-MTStartTab", in: arguments)
        coachURL = Self.value(after: "-MTCoachURL", in: arguments).flatMap(URL.init(string:))
    }

    /// The options of this process.
    static var current: LaunchOptions {
        #if DEBUG
        LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        #else
        LaunchOptions()
        #endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
