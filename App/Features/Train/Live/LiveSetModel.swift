import AVFoundation
import Domain
import MotionCore
import Observation
import PoseCapture
import SwiftUI

/// What a finished live set hands to the Train flow.
struct LiveSetResult {
    let summary: SetSummary
    let startedAt: Date
    let endedAt: Date
    /// The frame at the bottom of each counted rep, by rep number (1-based, as in the review).
    let bottomFrames: [Int: PoseFrame]
    let recording: PoseRecording?
    /// Why a requested pose recording could not be kept, if it could not.
    let recordingFailure: String?
}

/// A finished pose recording, still under its temporary name.
struct PoseRecording {
    let url: URL
    let frames: Int
    let fps: Double
}

/// The live depth signal, 0 at the top and 1 at the bottom of the calibrated range. It lives apart from the
/// model so that only the gauge re-renders on every frame.
@Observable
final class LiveSignal {
    var value = 0.0
}

/// A coaching cue on screen.
struct CueDisplay: Equatable, Identifiable {
    let id: Int
    let text: String
}

/// One live set: where frames come from (the camera, or a recording on the Simulator), the engine that counts
/// them, and everything the screen shows.
///
/// Threads: the camera delivers frames on its own queue. A single pump task (off the main actor) hands each
/// frame to the frame store, the overlay, the engine and the recorder. The overlay gets the newest frame through
/// a one-slot mailbox (at most one main-actor hop outstanding, at most 30 per second), so a busy main thread skips
/// drawings and never delays counting. The engine is an actor; its events come back to the main actor, which only
/// updates small values.
@MainActor
@Observable
final class LiveSetModel: Identifiable {
    enum Stage: Equatable {
        case preparing
        case running
        case cameraDenied
        case cameraRestricted
        case failed(String)
    }

    enum Source: Equatable {
        case camera
        case replay(String)
    }

    let id = UUID()
    let exercise: Exercise
    let spec: ExerciseSpec

    private(set) var stage = Stage.preparing
    private(set) var source = Source.camera
    private(set) var framing = FramingState.noPerson
    private(set) var reps = 0
    private(set) var partials = 0
    private(set) var lastRep: RepRecord?
    private(set) var cue: CueDisplay?
    /// Counts the cues shown, so a haptic can follow each one.
    private(set) var cueCount = 0
    /// The engine saw no movement for the idle time, or the source ran dry (a replay reached its end): the
    /// user is probably done and the set stays open until they end it.
    var isIdle: Bool { isEngineIdle || isSourceFinished }
    private var isEngineIdle = false
    private(set) var isSourceFinished = false
    private(set) var cameraPosition = CameraPosition.front
    private(set) var canSwitchCamera = false
    private(set) var isRecording = false
    private(set) var notice: String?
    var showsHUD = false

    let signal = LiveSignal()

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private weak var island: CameraIslandView?
    @ObservationIgnored private var camera: CameraPipeline?
    @ObservationIgnored private var session: MotionSession?
    @ObservationIgnored private var recorder: PoseRecorder?
    @ObservationIgnored private let frameStore = FrameStore()
    @ObservationIgnored private let latestFrame = LatestFrame()
    @ObservationIgnored private let cuePlayer = CuePlayer()
    @ObservationIgnored private var pumpTask: Task<String?, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var cameraEventTask: Task<Void, Never>?
    @ObservationIgnored private var cueTask: Task<Void, Never>?
    @ObservationIgnored private var haltTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var isPreviewConnected = false
    @ObservationIgnored private var speaksCues = true
    @ObservationIgnored private var wantsRecording = false
    @ObservationIgnored private var startedAt: Date?
    @ObservationIgnored private var finalSummary: SetSummary?
    @ObservationIgnored private var recordingFailure: String?
    @ObservationIgnored private var counted: [RepRecord] = []
    @ObservationIgnored private var bottomFrames: [Int: PoseFrame] = [:]
    @ObservationIgnored private var isReplayHeld = false
    @ObservationIgnored private var delivered = 0
    @ObservationIgnored private var deliveryStart: ContinuousClock.Instant?

    init(environment: AppEnvironment, exercise: Exercise, spec: ExerciseSpec) {
        self.environment = environment
        self.exercise = exercise
        self.spec = spec
        showsHUD = environment.launch.debugHUD
    }

    // MARK: Island

    /// Called once by `CameraIsland` with its UIKit view.
    func attach(island: CameraIslandView) {
        self.island = island
        island.setBackdrop(source == .camera ? .camera : .plain)
        island.quarterTurns = { [weak self] in self?.camera?.overlayQuarterTurns ?? 0 }
        connectPreviewIfNeeded()
    }

    private func connectPreviewIfNeeded() {
        guard !isPreviewConnected, let island, let camera else { return }
        camera.connectPreview(to: island.previewLayer)
        isPreviewConnected = true
    }

    // MARK: Start

    /// Chooses the frame source and starts counting. Safe to call again: only the first call does anything,
    /// except after a denied permission was changed (`recheckPermission`).
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        speaksCues = (try? await environment.settings.get(SettingKey.voiceCues)) ?? true
        let stored = (try? await environment.settings.get(SettingKey.recordPoses)) ?? false
        wantsRecording = stored || environment.launch.recordPoses
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
            // The Simulator has no camera: replay a bundled recording so the whole flow can be tried.
            await beginReplay(named: ReplayFixtures.defaultName(forSpecID: spec.id))
            #else
            // A device must never count a recording as if it were the user.
            stage = .failed(String(localized: "This device has no camera."))
            #endif
            return
        }
        cameraPosition = cameras.front ? .front : .back
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
        source = .replay(name)
        island?.setBackdrop(.plain)
        let replay = ReplayPoseSource(fixture: fixture, pacing: .realTime(speed: environment.launch.replaySpeed))
        await beginCapture(frames: replay.frames())
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
        guard haltTask == nil else {
            await camera?.stop()
            return
        }
        let session: MotionSession
        do {
            session = try MotionSession(spec: spec)
        } catch {
            stage = .failed(error.localizedDescription)
            await camera?.stop()
            return
        }
        self.session = session
        startedAt = environment.now()
        recorder = makeRecorder()
        stage = .running

        eventTask = Task { [weak self] in
            for await event in session.events { self?.handle(event) }
        }
        let store = frameStore
        let latest = latestFrame
        let recorder = recorder
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            await Self.pump(frames, session: session, store: store, latest: latest, recorder: recorder) {
                Task { @MainActor in self?.drawLatestFrame() }
            } onEnd: {
                self?.sourceDidFinish()
            }
        }
    }

    /// Hands every frame to the store, the overlay, the engine and the recorder, in that order, until the source
    /// ends or the task is cancelled. Nothing in the loop waits for the main thread. Returns why recording
    /// stopped early, if it did.
    @concurrent
    private static func pump(
        _ frames: AsyncStream<PoseFrame>,
        session: MotionSession,
        store: FrameStore,
        latest: LatestFrame,
        recorder: PoseRecorder?,
        scheduleDraw: @Sendable () -> Void,
        onEnd: @MainActor @Sendable () -> Void
    ) async -> String? {
        var recorder = recorder
        var failure: String?
        for await frame in frames {
            store.append(frame)
            if latest.put(frame) { scheduleDraw() }
            await session.process(frame)
            if let active = recorder {
                do {
                    try await active.append(frame)
                } catch {
                    failure = error.localizedDescription
                    recorder = nil
                }
            }
        }
        // Flush a rep that is still inside its settle window; harmless when the set is being ended anyway.
        _ = await session.finish()
        await onEnd()
        return failure
    }

    private func makeRecorder() -> PoseRecorder? {
        guard wantsRecording else { return nil }
        let url = PoseCaptureFiles.directory.appending(path: "pending-\(UUID().uuidString).jsonl", directoryHint: .notDirectory)
        let header = PoseFixtureHeader(
            exerciseSpecID: spec.id,
            cameraPosition: source == .camera ? cameraPosition : .unknown,
            deviceModel: UIDevice.current.model
        )
        do {
            let recorder = try PoseRecorder(url: url, header: header)
            isRecording = true
            return recorder
        } catch {
            recordingFailure = error.localizedDescription
            return nil
        }
    }

    // MARK: Frames and events

    /// Draws the newest frame the pump has left in the mailbox.
    private func drawLatestFrame() {
        guard let frame = latestFrame.take() else { return }
        island?.update(frame)
        if deliveryStart == nil { deliveryStart = ContinuousClock.now }
        delivered += 1
    }

    private func sourceDidFinish() {
        // The pump also ends when the set is being ended; only a source that ran dry on its own is news.
        guard haltTask == nil else { return }
        isSourceFinished = true
    }

    /// A replay that has shown enough: stop feeding it and keep the screen as it is (screenshots and UI tests).
    private func holdReplayIfWanted() {
        guard case .replay = source, let hold = environment.launch.replayHoldReps, reps >= hold, !isReplayHeld else { return }
        isReplayHeld = true
        pumpTask?.cancel()
    }

    private func handle(_ event: MotionEvent) {
        switch event {
        case .framing(let state):
            framing = state
            if state.isReady { isEngineIdle = false }
        case .phase:
            isEngineIdle = false
        case .repCompleted(let record):
            counted.append(record)
            reps = counted.count
            lastRep = record
            isEngineIdle = false
            // The engine reports a rep after it ended; the frame of its bottom is still in the store.
            if let frame = frameStore.frame(nearest: record.tBottom) {
                bottomFrames[reps] = frame
            }
            holdReplayIfWanted()
        case .partialRep:
            partials += 1
            isEngineIdle = false
        case .cue(let key):
            show(cue: LiveText.cue(key))
        case .signal(let value):
            signal.value = value
        case .idle:
            isEngineIdle = true
        }
    }

    private func show(cue text: String) {
        cueCount += 1
        cue = CueDisplay(id: cueCount, text: text)
        if speaksCues { cuePlayer.speak(text) }
        cueTask?.cancel()
        // A held replay keeps its last cue on screen: nothing else is going to change.
        guard !isReplayHeld else { return }
        cueTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.cue = nil }
        }
    }

    private func handle(cameraEvent event: CameraEvent) {
        switch event {
        case .interrupted:
            notice = String(localized: "Camera interrupted")
        case .interruptionEnded:
            notice = nil
        case .runtimeError(let message):
            notice = message
        case .started, .cameraChanged, .stopped, .pressure:
            break
        }
    }

    // MARK: Controls

    func switchCamera() async {
        guard let camera, canSwitchCamera else { return }
        let next: CameraPosition = cameraPosition == .front ? .back : .front
        do {
            try await camera.switchCamera(to: next)
            cameraPosition = next
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Camera numbers for the debug HUD; nil while replaying.
    var cameraStats: CameraStats? { camera?.stats }

    /// Frames per second delivered to the overlay since the set began, and how many there were.
    var deliveryRate: (fps: Double, frames: Int) {
        guard let deliveryStart else { return (0, 0) }
        let elapsed = deliveryStart.duration(to: ContinuousClock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return (seconds > 0 ? Double(delivered) / seconds : 0, delivered)
    }

    // MARK: Ending

    /// Stops the camera and the engine and returns what was counted, or nil when no rep was.
    func endSet() async -> LiveSetResult? {
        await halt()
        let summary = finalSummary ?? SetSummary()
        let finishedAt = environment.now()

        var recording: PoseRecording?
        if let recorder {
            do {
                let header = try await recorder.finish(labels: PoseLabels(
                    reps: summary.reps, partials: summary.partials, tags: source == .camera ? [] : ["replay"]
                ))
                recording = PoseRecording(url: recorder.url, frames: header.frameCount ?? 0, fps: header.fps ?? 30)
            } catch {
                recordingFailure = recordingFailure ?? error.localizedDescription
            }
        }
        self.recorder = nil
        isRecording = false
        guard summary.reps > 0 else {
            if let recording { try? FileManager.default.removeItem(at: recording.url) }
            return nil
        }
        return LiveSetResult(
            summary: summary,
            startedAt: startedAt ?? finishedAt,
            endedAt: finishedAt,
            bottomFrames: bottomFrames,
            recording: recording,
            recordingFailure: recordingFailure
        )
    }

    /// Stops everything and drops the recording. Used when the screen goes away without a result.
    func stop() async {
        await halt()
        if let recorder {
            _ = try? await recorder.finish()
            try? FileManager.default.removeItem(at: recorder.url)
        }
        isRecording = false
    }

    private func halt() async {
        if haltTask == nil {
            haltTask = Task { await self.performHalt() }
        }
        await haltTask?.value
    }

    private func performHalt() async {
        pumpTask?.cancel()
        cueTask?.cancel()
        cameraEventTask?.cancel()
        let failure = await pumpTask?.value
        recordingFailure = recordingFailure ?? failure
        await camera?.stop()
        finalSummary = await session?.finish()
        await eventTask?.value
        cuePlayer.stop()
    }
}
