import AVFoundation
import AppLogic
import Domain
import Foundation
import MotionCore
import Observation
import PoseCapture
import SwiftUI
import UIKit

/// Why a demonstration was not accepted, in the terms of what the user should change.
enum TeachProblem: Equatable {
    case noMotion
    case tooFew(found: Int)
    case mismatch(counted: Int, expected: Int)
    case partial(Int)
    case small
    case uneven
    case hidden

    init(_ failure: TaughtFailure) {
        switch failure {
        case .noReps: self = .noMotion
        case .countMismatch(let counted, let expected): self = .mismatch(counted: counted, expected: expected)
        case .partialsInDemo(let count): self = .partial(count)
        case .romTooSmall: self = .small
        case .inconsistentDepth: self = .uneven
        case .jointsUnreliable: self = .hidden
        // Only form checks produce this, and slice A's spec has none.
        case .ruleFailsDemo: self = .uneven
        }
    }
}

/// What checking a demonstration produced, computed off the main actor.
nonisolated struct TeachVerdict: Sendable {
    var spec: ExerciseSpec
    var verification: TaughtVerification
}

/// Teaching the app a new exercise: a name, the camera framing, a countdown, a demonstration, the user's count
/// of it, the replay that checks the count, and saving.
///
/// The camera side follows `LiveSetModel`: one pump task, off the main actor, hands each frame to the overlay
/// and to the `TeachSession`; the model only keeps small values. A device without a camera fails (it never
/// replays a recording as if it were the user); the Simulator and `-MTReplayPoses` play a bundled one.
@MainActor
@Observable
final class TeachModel {
    enum Stage: Equatable {
        case preparing
        case running
        case cameraDenied
        case cameraRestricted
        case failed(String)
    }

    enum Step: Equatable {
        case name
        case framing
        case countdown
        case recording
        /// The demonstration is being studied.
        case studying
        case confirm
        case verified
        case failed(TeachProblem)
        /// The exercise is kept without the camera after the demonstration would not verify.
        case manual
        case saved
    }

    /// Longest demonstration; it ends by itself.
    static let maxSeconds = 45.0
    static let countdownSeconds = 3
    static let repsAsked = 3
    static let repRange = 1...10
    /// After this many failed attempts the exercise can still be kept, for logging by hand.
    static let attemptsBeforeManual = 3

    private(set) var step = Step.name
    private(set) var stage = Stage.preparing
    private(set) var source = Source.camera
    private(set) var framing = FramingState.noPerson
    private(set) var countdown = 0
    private(set) var elapsed = 0.0
    private(set) var repsSeen = 0
    private(set) var cameraPosition = CameraPosition.front
    private(set) var canSwitchCamera = false
    private(set) var notice: String?
    private(set) var isWorking = false
    private(set) var failures = 0
    private(set) var countedReps = 0
    /// The two poses the exercise is made of, for the confirmation card.
    private(set) var topFrame: PoseFrame?
    private(set) var bottomFrame: PoseFrame?
    private(set) var savedExercise: Exercise?

    /// The user's answer to "how many did you do?".
    var confirmedReps = TeachModel.repsAsked
    var name = ""
    var muscles: Set<MuscleGroup> = []
    var equipment = Equipment.bodyweight
    var errorMessage: String?

    enum Source: Equatable {
        case camera
        case replay
    }

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var exerciseID: ExerciseID?
    @ObservationIgnored private var cleanName = ""
    @ObservationIgnored private let session = TeachSession()
    @ObservationIgnored private let latestFrame = LatestFrame()
    @ObservationIgnored private let cuePlayer = CuePlayer()
    @ObservationIgnored private weak var island: CameraIslandView?
    @ObservationIgnored private var camera: CameraPipeline?
    @ObservationIgnored private var replay: TeachReplayFeed?
    @ObservationIgnored private var pumpTask: Task<Void, Never>?
    @ObservationIgnored private var cameraEventTask: Task<Void, Never>?
    @ObservationIgnored private var takeTask: Task<Void, Never>?
    @ObservationIgnored private var isPreviewConnected = false
    @ObservationIgnored private var hasStartedCamera = false
    @ObservationIgnored private var speaksCues = true
    @ObservationIgnored private var result: TeachResult?
    @ObservationIgnored private var verifiedSpec: ExerciseSpec?
    @ObservationIgnored private var isStopped = false

    init(environment: AppEnvironment, name: String = "") {
        self.environment = environment
        self.name = String(name.prefix(TaughtExercise.maxNameLength))
    }

    // MARK: Island

    /// Called by `TeachCameraIsland` with its UIKit view. The view is made again for every try.
    func attach(island: CameraIslandView) {
        self.island = island
        island.setBackdrop(source == .camera ? .camera : .plain)
        island.quarterTurns = { [weak self] in self?.camera?.overlayQuarterTurns ?? 0 }
        isPreviewConnected = false
        connectPreviewIfNeeded()
    }

    private func connectPreviewIfNeeded() {
        guard !isPreviewConnected, let island, let camera else { return }
        camera.connectPreview(to: island.previewLayer)
        isPreviewConnected = true
    }

    // MARK: Name

    private var catalog: [Exercise] = []

    func loadCatalog() async {
        catalog = (try? await environment.exercises.allExercises()) ?? []
    }

    /// An exercise the user already has under this name; teaching it again is not offered.
    var existingExercise: Exercise? {
        TaughtExercise.existing(named: name, in: catalog, displayName: ExerciseNames.name(of:))
    }

    var validName: String? {
        if case .success(let valid) = TaughtExercise.validate(name) { valid } else { nil }
    }

    /// The name is taken: on to the camera.
    func continueFromName() {
        guard step == .name, existingExercise == nil, let valid = validName else { return }
        cleanName = valid
        if exerciseID == nil {
            exerciseID = TaughtExercise.makeID(name: valid, randomness: .random(in: 0...UInt64.max))
        }
        step = .framing
        Task { await startCamera() }
    }

    // MARK: Camera

    private func startCamera() async {
        guard !hasStartedCamera, !isStopped else { return }
        hasStartedCamera = true
        speaksCues = (try? await environment.settings.get(SettingKey.voiceCues)) ?? true
        await chooseSource()
    }

    /// The user may have allowed the camera in Settings while the permission screen was up.
    func recheckPermission() async {
        guard stage == .cameraDenied || stage == .cameraRestricted else { return }
        guard environment.launch.cameraState == nil, CameraAuthorization.current == .authorized else { return }
        stage = .preparing
        await beginCamera()
    }

    private func chooseSource() async {
        let launch = environment.launch
        if let name = launch.replayPoses {
            await beginReplay(named: name)
            return
        }
        switch launch.cameraState {
        case "denied":
            stage = .cameraDenied
            return
        case "restricted":
            stage = .cameraRestricted
            return
        default:
            break
        }

        let cameras = await Self.availableCameras()
        guard cameras.front || cameras.back else {
            #if targetEnvironment(simulator)
            // The Simulator has no camera: a bundled recording lets the whole flow be tried.
            await beginReplay(named: "squat")
            #else
            // A device must never count a recording as if it were the user.
            stage = .failed(String(localized: "This device has no camera."))
            #endif
            return
        }
        let preferred = try? await environment.settings.get(SettingKey.preferredCamera)
        cameraPosition = (preferred == "back" && cameras.back) || !cameras.front ? .back : .front
        canSwitchCamera = cameras.front && cameras.back

        switch CameraAuthorization.current {
        case .authorized:
            await beginCamera()
        case .notDetermined:
            if await CameraAuthorization.request() {
                await beginCamera()
            } else {
                stage = .cameraDenied
            }
        case .denied:
            stage = .cameraDenied
        case .restricted:
            stage = .cameraRestricted
        }
    }

    @concurrent
    private static func availableCameras() async -> (front: Bool, back: Bool) {
        (!CameraPipeline.cameras(at: .front).isEmpty, !CameraPipeline.cameras(at: .back).isEmpty)
    }

    private func beginReplay(named name: String) async {
        let fixture: PoseFixture
        do {
            fixture = try await ReplayFixtures.load(named: name)
        } catch {
            stage = .failed(error.localizedDescription)
            return
        }
        let speed = environment.launch.replaySpeed
        let feed = await Self.makeFeed(fixture, speed: speed)
        replay = feed
        source = .replay
        island?.setBackdrop(.plain)
        await beginCapture(frames: feed.frames())
    }

    @concurrent
    private static func makeFeed(_ fixture: PoseFixture, speed: Double) async -> TeachReplayFeed {
        TeachReplayFeed(fixture: fixture, speed: speed)
    }

    private func beginCamera() async {
        source = .camera
        island?.setBackdrop(.camera)
        let pipeline = CameraPipeline(configuration: .init(position: cameraPosition))
        camera = pipeline
        do {
            try await pipeline.start()
        } catch CameraError.notAuthorized {
            camera = nil
            stage = .cameraDenied
            return
        } catch {
            camera = nil
            stage = .failed(error.localizedDescription)
            return
        }
        connectPreviewIfNeeded()
        cameraEventTask = Task { [weak self] in
            for await event in pipeline.events { self?.handle(cameraEvent: event) }
        }
        await beginCapture(frames: pipeline.frames)
    }

    private func beginCapture(frames: AsyncStream<PoseFrame>) async {
        // The screen may have gone away while the camera was starting.
        guard !isStopped else {
            await camera?.stop()
            return
        }
        stage = .running
        let session = session
        let latest = latestFrame
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.pump(frames, session: session, latest: latest) {
                Task { @MainActor in self?.drawLatestFrame() }
            } onFraming: { state in
                self?.framing = state
            }
        }
    }

    /// Hands every frame to the overlay and to the session, until the source ends or the task is cancelled.
    /// Nothing in the loop waits for the main thread.
    @concurrent
    private static func pump(
        _ frames: AsyncStream<PoseFrame>,
        session: TeachSession,
        latest: LatestFrame,
        scheduleDraw: @Sendable () -> Void,
        onFraming: @MainActor @Sendable (FramingState) -> Void
    ) async {
        var last: FramingState?
        for await frame in frames {
            if latest.put(frame) { scheduleDraw() }
            let state = await session.process(frame)
            if state != last {
                last = state
                await onFraming(state)
            }
        }
    }

    private func drawLatestFrame() {
        guard let frame = latestFrame.take() else { return }
        island?.update(frame)
    }

    private func handle(cameraEvent event: CameraEvent) {
        switch event {
        case .interrupted: notice = String(localized: "Camera interrupted")
        case .interruptionEnded: notice = nil
        case .runtimeError(let message): notice = message
        case .started, .cameraChanged, .stopped, .pressure: break
        }
    }

    func switchCamera() async {
        guard let camera, canSwitchCamera else { return }
        let next: CameraPosition = cameraPosition == .front ? .back : .front
        do {
            try await camera.switchCamera(to: next)
            cameraPosition = next
            try await environment.settings.set(SettingKey.preferredCamera, to: next == .back ? "back" : "front")
        } catch {
            notice = error.localizedDescription
        }
    }

    // MARK: Demonstrating

    /// "Start": the countdown, then the demonstration. The frames of the countdown are part of the take (the
    /// replay needs the person standing still in the starting position before the first rep), but what is
    /// learned starts with the last second of it.
    func start() {
        guard step == .framing, framing.isReady, takeTask == nil else { return }
        repsSeen = 0
        elapsed = 0
        takeTask = Task { await runTake() }
    }

    private func runTake() async {
        await session.beginTake()
        step = .countdown
        for second in stride(from: Self.countdownSeconds, through: 1, by: -1) {
            countdown = second
            if speaksCues { cuePlayer.speak(String(second)) }
            if second == 1 { await session.beginAnalysis() }
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return }
        }
        countdown = 0
        step = .recording
        replay?.release()

        let began = ContinuousClock.now
        var ticks = 0
        while step == .recording, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            let spent = began.duration(to: ContinuousClock.now)
            elapsed = Double(spent.components.seconds) + Double(spent.components.attoseconds) / 1e18
            ticks += 1
            if ticks % 4 == 0 { repsSeen = await session.provisionalCycleCount() }
            let isFull = await session.isFull
            if elapsed >= Self.maxSeconds || isFull { break }
        }
        guard step == .recording, !Task.isCancelled else { return }
        await study()
    }

    /// "Done", or the end of the longest demonstration.
    func finishRecording() {
        guard step == .recording else { return }
        Task { await study() }
    }

    private func study() async {
        guard step == .recording else { return }
        step = .studying
        takeTask?.cancel()
        takeTask = nil
        do {
            let learned = try await session.finish()
            result = learned
            confirmedReps = min(max(learned.detectedReps, Self.repRange.lowerBound), Self.repRange.upperBound)
            step = .confirm
        } catch TeachError.tooFewReps(let found, _) {
            fail(.tooFew(found: found))
        } catch {
            fail(.noMotion)
        }
    }

    // MARK: Checking

    /// The user's count is in: replay the demonstration through the engine and see whether it counts the same.
    func confirm() {
        guard step == .confirm, !isWorking, let result, let exerciseID else { return }
        isWorking = true
        let reps = confirmedReps
        Task {
            defer { isWorking = false }
            do {
                let verdict = try await Self.verify(result, reps: reps, specID: exerciseID.rawValue)
                if let failure = verdict.verification.failure {
                    fail(TeachProblem(failure))
                    return
                }
                verifiedSpec = verdict.spec
                countedReps = verdict.verification.counted
                topFrame = result.topFrame
                bottomFrame = result.bottomFrame
                step = .verified
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @concurrent
    private static func verify(_ result: TeachResult, reps: Int, specID: String) async throws -> TeachVerdict {
        let outcome = try TaughtVerifier.verifyChoosingView(spec: result.spec(id: specID), take: result.take(confirming: reps))
        return TeachVerdict(spec: outcome.spec, verification: outcome.verification)
    }

    private func fail(_ problem: TeachProblem) {
        failures += 1
        step = .failed(problem)
    }

    /// Back to the framing for another try; the name stays.
    func retry() {
        guard case .failed = step else { return }
        result = nil
        verifiedSpec = nil
        repsSeen = 0
        elapsed = 0
        replay?.rewind()
        Task { await session.discardTake() }
        step = .framing
    }

    /// After repeated failures the exercise can still be kept, for logging by hand.
    func chooseManual() {
        guard case .failed = step, failures >= Self.attemptsBeforeManual else { return }
        step = .manual
    }

    // MARK: Saving

    var canSave: Bool { !muscles.isEmpty && !isWorking }

    func save() {
        guard step == .verified || step == .manual, canSave, let exerciseID else { return }
        isWorking = true
        let isManual = step == .manual
        let spec = isManual ? nil : verifiedSpec
        let learned = result
        let reps = confirmedReps
        let muscles = muscles.sorted { $0.rawValue < $1.rawValue }
        let equipment = equipment
        let name = cleanName
        let position = cameraPosition
        let usedReplay = source == .replay
        Task {
            defer { isWorking = false }
            do {
                let id = isManual ? ExerciseID("custom.\(TaughtExercise.slug(name)).\(String(format: "%06x", Int.random(in: 0...0xFF_FFFF)))") : exerciseID
                let exercise = Exercise(
                    id: id, name: name, category: .strength, primaryMuscles: muscles, equipment: equipment,
                    specID: spec == nil ? nil : id.rawValue
                )
                if let spec {
                    let json = try JSONPayload(encoding: spec)
                    try await TaughtExerciseSaver(store: environment.exercises).save(
                        exercise: exercise, specJSON: json, specRowID: environment.newID(), now: environment.now()
                    )
                    ExerciseSpecCatalog.register(spec, for: id)
                    if let learned {
                        // The demonstration is kept for re-checking the spec later; losing it loses nothing else.
                        try? await TaughtDemoFiles.write(
                            learned.frames, exerciseID: id, reps: reps, camera: usedReplay ? .unknown : position
                        )
                    }
                } else {
                    try await environment.exercises.save(exercise)
                }
                savedExercise = exercise
                step = .saved
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: Ending

    /// Stops the camera and everything running. Safe to call more than once.
    func stop() async {
        isStopped = true
        takeTask?.cancel()
        takeTask = nil
        pumpTask?.cancel()
        cameraEventTask?.cancel()
        cuePlayer.stop()
        await camera?.stop()
        camera = nil
    }
}

/// Where the demonstration of a taught exercise is kept: on the phone only, as a pose recording (joint
/// positions, no picture), next to the exercise's spec.
enum TaughtDemoFiles {
    nonisolated static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "MovementTracker", directoryHint: .isDirectory)
            .appending(path: "TaughtDemos", directoryHint: .isDirectory)
    }

    nonisolated static func url(for exerciseID: ExerciseID) -> URL {
        directory.appending(path: "\(exerciseID.rawValue).jsonl", directoryHint: .notDirectory)
    }

    @concurrent
    static func write(_ frames: [PoseFrame], exerciseID: ExerciseID, reps: Int, camera: CameraPosition) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let header = PoseFixtureHeader(
            exerciseSpecID: exerciseID.rawValue, cameraPosition: camera, fps: 30,
            created: Date(), labels: PoseLabels(reps: reps, tags: ["taught"]),
            frameCount: frames.count, duration: (frames.last?.t ?? 0) - (frames.first?.t ?? 0)
        )
        try PoseFixtureFile.write(PoseFixture(header: header, frames: frames), to: url(for: exerciseID))
    }
}
