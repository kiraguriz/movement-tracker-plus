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
/// - `-MTReplayPoses <name>`: a live set replays the bundled pose recording `<name>` (`squat` or `pushup`) instead
///   of using the camera. Without this argument replay also starts when the device has no camera.
/// - `-MTReplaySpeed <factor>`: plays the replay faster (UI tests use 3); the engine runs on recorded time, so
///   the counts do not change.
/// - `-MTReplayHoldReps <n>`: a replay stops after the n-th counted rep and the screen stays as it is, so a
///   screenshot or a UI test sees a settled state.
/// - `-MTCameraState denied|restricted`: shows that camera-permission state in a live set without touching the
///   real permission.
/// - `-MTDebugHUD`: shows the camera and engine numbers in a live set from the start (a long press on the rep
///   counter toggles them).
/// - `-MTRecordPoses`: records every live set's poses as if the setting were on.
/// - `-MTCoachStub`: build the coach over a canned, in-process transport (no network, not Muse). Wins over
///   `-MTCoachURL`. `-MTCoachStubFail offline|budget|paused` makes every call fail that way.
/// - `-MTAIOptIn`: with the in-memory database, start with the coach consent already given.
/// - `-MTMealPhotoSample`: the meal photo sheet offers a generated sample photo (the Simulator has no camera).
/// - `-MTHealthStub`: Apple Health runs over an in-process fake that records what would be written or removed and
///   answers the access request without the system sheet; Me shows its counters. `-MTHealthStub denied` makes the
///   access request come back denied. The stub is not compiled into Release, and neither is this flag.
struct LaunchOptions: Equatable {
    enum Seed: String {
        case none, profile, sample
    }

    var inMemoryDatabase = false
    var seed = Seed.none
    var startTab: String?
    var failDatabase = false
    var coachURL: URL?
    var replayPoses: String?
    var replaySpeed = 1.0
    var replayHoldReps: Int?
    var cameraState: String?
    var debugHUD = false
    var recordPoses = false
    var coachStub = false
    var coachStubFailure: String?
    var aiOptIn = false
    var mealPhotoSample = false
    #if DEBUG
    var healthStub = false
    var healthStubDenies = false
    #endif

    init() {}

    init(arguments: [String]) {
        inMemoryDatabase = arguments.contains("-MTInMemoryDatabase")
        failDatabase = arguments.contains("-MTFailDatabase")
        seed = Self.value(after: "-MTSeed", in: arguments).flatMap(Seed.init(rawValue:)) ?? .none
        startTab = Self.value(after: "-MTStartTab", in: arguments)
        coachURL = Self.value(after: "-MTCoachURL", in: arguments).flatMap(Self.proxyURL)
        replayPoses = Self.value(after: "-MTReplayPoses", in: arguments)
        replaySpeed = Self.value(after: "-MTReplaySpeed", in: arguments).flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 1
        replayHoldReps = Self.value(after: "-MTReplayHoldReps", in: arguments).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        cameraState = Self.value(after: "-MTCameraState", in: arguments)
        debugHUD = arguments.contains("-MTDebugHUD")
        recordPoses = arguments.contains("-MTRecordPoses")
        coachStub = arguments.contains("-MTCoachStub")
        coachStubFailure = Self.value(after: "-MTCoachStubFail", in: arguments)
        aiOptIn = arguments.contains("-MTAIOptIn")
        mealPhotoSample = arguments.contains("-MTMealPhotoSample")
        #if DEBUG
        healthStub = arguments.contains("-MTHealthStub")
        healthStubDenies = healthStub && Self.value(after: "-MTHealthStub", in: arguments) == "denied"
        #endif
    }

    /// The options of this process.
    static var current: LaunchOptions {
        #if DEBUG
        LaunchOptions(arguments: ProcessInfo.processInfo.arguments)
        #else
        LaunchOptions()
        #endif
    }

    /// An http(s) address with a host; anything else would only fail later, inside a request.
    private static func proxyURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.host() != nil, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
