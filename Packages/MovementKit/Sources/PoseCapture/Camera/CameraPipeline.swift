#if os(iOS)
import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import MotionCore
import OSLog
import Synchronization

private let log = Logger(subsystem: "MovementTracker", category: "PoseCapture")

// MARK: - Support types

public enum CameraError: Error, Equatable, LocalizedError, Sendable {
    case notAuthorized
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case configurationFailed(String)
    /// `stop()` was called: make a new pipeline for the next set.
    case finished

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: "Camera access is not allowed."
        case .noCamera: "No camera is available."
        case .cannotAddInput: "The camera could not be added to the capture session."
        case .cannotAddOutput: "The video output could not be added to the capture session."
        case let .configurationFailed(reason): "The camera could not be configured: \(reason)"
        case .finished: "This camera pipeline was stopped; create a new one."
        }
    }
}

/// One camera the system reports.
public struct CameraInfo: Equatable, Sendable {
    public var id: String
    public var name: String
    /// `AVCaptureDevice.DeviceType` raw value, for example `AVCaptureDeviceTypeBuiltInWideAngleCamera`.
    public var deviceType: String
    public var position: CameraPosition
}

public enum CameraEvent: Equatable, Sendable {
    case started(CameraInfo)
    case cameraChanged(CameraInfo)
    case stopped
    /// The session was interrupted (a call, another app using the camera, multitasking); frames stop
    /// until `interruptionEnded`.
    case interrupted(reason: String)
    case interruptionEnded
    case runtimeError(String)
    /// Thermal or system pressure changed; the pipeline already lowered the frame rate if needed.
    case pressure(CapturePressure, frameRate: Double)
}

public enum CameraAuthorization: Sendable {
    case notDetermined, restricted, denied, authorized

    public static var current: CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    /// Asks for access if it was never asked (the system prompt needs `NSCameraUsageDescription`). True when
    /// the camera may be used.
    public static func request() async -> Bool {
        switch current {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        case .restricted, .denied: false
        }
    }
}

// MARK: - Pipeline

/// Live camera to `PoseFrame`s (brief §5.3).
///
/// Threading: the pipeline is a plain class, not an actor. `AVCaptureSession` configuration, start/stop and
/// camera switches run on `sessionQueue`; frames arrive on `videoQueue` (`alwaysDiscardsLateVideoFrames`,
/// bi-planar 4:2:0), where Vision runs to completion before the callback returns, so a `CVPixelBuffer`
/// never leaves that queue. Results leave through `frames`, an `AsyncStream` that keeps only the newest
/// frame. Nothing here runs on the main thread except the preview hookup.
///
/// Usage:
/// ```swift
/// guard await CameraAuthorization.request() else { /* show settings prompt */ return }
/// let camera = CameraPipeline()                          // front camera, 30 fps
/// try await camera.start()                               // off the main thread
/// Task { for await frame in camera.frames { await session.process(frame) } }
/// // preview (main actor, UIKit island): previewView.layer is an AVCaptureVideoPreviewLayer
/// camera.connectPreview(to: previewView.previewLayer)
/// // HUD: poll camera.stats a few times a second
/// await camera.stop()
/// ```
///
/// A frame with no joints means Vision found nobody in that camera frame.
///
/// Coordinates: x is mirrored for the front camera, so a frame matches what the (mirrored) preview shows;
/// the back camera is not mirrored. The preview layer rotates itself through its own
/// `AVCaptureDevice.RotationCoordinator` (preview angle); Vision gets the capture angle from another one.
/// The two angles agree while the interface turns with the device. When it does not (an interface locked
/// to portrait, the phone held in landscape) the frames stay upright while the preview stays fixed to the
/// phone: build the overlay with `OverlayMapping(quarterTurns: camera.overlayQuarterTurns)`.
///
/// Ending: `stop()` finishes both streams. So does the consumer of `frames` leaving its loop (cancelled
/// or `break`): nobody is left to read the frames, so the session is stopped instead of running Vision for
/// nothing.
public final class CameraPipeline: @unchecked Sendable {
    public struct Configuration: Equatable, Sendable {
        public var position: CameraPosition = .front
        public var frameRate: Double = 30
        /// The wanted frame height; the closest format is used (720 or 1080 on current iPhones).
        public var preferredHeight: Int = 720
        /// Use this exact camera (`CameraInfo.id`) instead of the standard wide one, for example to try an
        /// alternative front camera on a foldable.
        public var preferredCameraID: String?

        public init(position: CameraPosition = .front, frameRate: Double = 30, preferredHeight: Int = 720, preferredCameraID: String? = nil) {
            self.position = position
            self.frameRate = frameRate
            self.preferredHeight = preferredHeight
            self.preferredCameraID = preferredCameraID
        }
    }

    /// What the video queue needs for each frame; written by the session queue and the rotation observer.
    private struct CaptureParameters: Sendable {
        /// The capture rotation angle in degrees and the orientation it stands for.
        var angle = 0.0
        var orientation: CGImagePropertyOrientation = .up
        var mirrored = false
    }

    private struct Metrics: Sendable {
        var latencies = LatencyWindow(capacity: 120)
        var meter = FrameRateMeter(window: 1)
        var dropped = 0
        var processed = 0
        var withPerson = 0
        var failures = 0
        var pressure = CapturePressure.nominal
        var targetFrameRate = 0.0
        var format = ""
        var cameraName = ""
        var centerStageActive = false
        var stabilizationActive = false
    }

    public let configuration: Configuration
    /// Pose frames, newest only (a slow consumer skips frames, like the camera does).
    public let frames: AsyncStream<PoseFrame>
    /// Lifecycle, interruptions, errors and pressure changes.
    public let events: AsyncStream<CameraEvent>

    private let estimator: VisionPoseEstimator
    private let frameContinuation: AsyncStream<PoseFrame>.Continuation
    private let eventContinuation: AsyncStream<CameraEvent>.Continuation
    private let sessionQueue = DispatchQueue(label: "MovementTracker.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "MovementTracker.camera.video", qos: .userInitiated)
    private let capture = Mutex(CaptureParameters())
    private let metrics = Mutex(Metrics())
    private let camera = Mutex<CameraInfo?>(nil)
    /// Where `PersonTracker` is in following one person; confined to the video queue by use.
    private let tracking = Mutex(PersonTracker())
    /// The angle the preview layer is rotated by, once a preview is connected.
    private let previewAngle = Mutex<Double?>(nil)
    /// The active device for the preview hookup, readable without waiting for the session queue.
    private let activeDevice = Mutex<UncheckedSendable<AVCaptureDevice>?>(nil)

    // Confined to `sessionQueue`.
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var wantedPosition: CameraPosition
    private var outputConfigured = false
    private var configured = false
    private var finished = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []
    private var delegate: SampleDelegate?

    // Confined to the main actor.
    @MainActor private var previewBinding: PreviewBinding?

    public init(configuration: Configuration = Configuration(), estimator: VisionPoseEstimator = VisionPoseEstimator()) {
        self.configuration = configuration
        self.estimator = estimator
        wantedPosition = configuration.position == .back ? .back : .front
        (frames, frameContinuation) = AsyncStream.makeStream(of: PoseFrame.self, bufferingPolicy: .bufferingNewest(1))
        (events, eventContinuation) = AsyncStream.makeStream(of: CameraEvent.self, bufferingPolicy: .unbounded)
        // The frame stream ends when `stop()` finishes it, and also when its only consumer goes away.
        frameContinuation.onTermination = { [weak self] _ in self?.consumerEnded() }
    }

    deinit {
        frameContinuation.finish()
        eventContinuation.finish()
        // Nothing else can touch these any more; the block-based observers would otherwise stay registered.
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        let box = UncheckedSendable(session)
        sessionQueue.async { if box.value.isRunning { box.value.stopRunning() } }
    }

    /// The frame stream ended. If `stop()` did not cause that, stop the session now.
    private func consumerEnded() {
        sessionQueue.async { self.shutDown() }
    }

    // MARK: - Control

    /// Configures the session (first call only) and starts it. Runs on the session queue; the caller may be on
    /// any thread. Throws `CameraError.notAuthorized` if camera access is not granted (it asks if never asked).
    public func start() async throws {
        guard await CameraAuthorization.request() else { throw CameraError.notAuthorized }
        try await onSessionQueue { try self.configureIfNeededAndStart() }
        // A preview connected before the camera existed has no device to take its rotation from yet.
        await rebindPreview()
    }

    /// Stops the session and finishes `frames` and `events`. The pipeline cannot be restarted.
    public func stop() async {
        await onSessionQueue { self.shutDown() }
        await MainActor.run { self.disconnectPreview() }
    }

    /// Switches between the front and back camera while running. Frames keep flowing; x mirroring and the
    /// rotation follow the new camera.
    public func switchCamera(to position: CameraPosition) async throws {
        try await onSessionQueue {
            guard !self.finished else { throw CameraError.finished }
            self.wantedPosition = position == .back ? .back : .front
            guard self.configured else { return }
            try self.configureInput(restartObservers: true)
        }
        await rebindPreview()
    }

    /// The cameras the system reports for a position, in discovery order. Safe to call from any thread.
    public static func cameras(at position: CameraPosition) -> [CameraInfo] {
        discover(position: position).map(info(for:))
    }

    /// Live numbers for the Day-0 gate HUD. Cheap enough to poll a few times a second.
    public var stats: CameraStats {
        let parameters = capture.withLock { $0 }
        let preview = previewAngle.withLock { $0 }
        return metrics.withLock { m in
            CameraStats(
                visionLatency: m.latencies.summary, deliveredFPS: m.meter.fps, droppedFrames: m.dropped,
                framesProcessed: m.processed, framesWithPerson: m.withPerson, visionFailures: m.failures,
                pressure: m.pressure, targetFrameRate: m.targetFrameRate, format: m.format, cameraName: m.cameraName,
                orientation: parameters.orientation, isMirrored: parameters.mirrored,
                captureRotationAngle: parameters.angle, previewRotationAngle: preview,
                overlayQuarterTurns: Self.overlayTurns(parameters, preview: preview),
                centerStageActive: m.centerStageActive, stabilizationActive: m.stabilizationActive
            )
        }
    }

    /// Quarter turns for `OverlayMapping(quarterTurns:)`: how the preview picture is turned against the
    /// frames' picture. Zero until a preview is connected. Read it again when the device is rotated.
    public var overlayQuarterTurns: Int {
        Self.overlayTurns(capture.withLock { $0 }, preview: previewAngle.withLock { $0 })
    }

    private static func overlayTurns(_ parameters: CaptureParameters, preview: Double?) -> Int {
        guard let preview else { return 0 }
        return PoseGeometry.overlayQuarterTurns(captureAngle: parameters.angle, previewAngle: preview, mirrored: parameters.mirrored)
    }

    /// The camera in use, once started.
    public var currentCamera: CameraInfo? { camera.withLock { $0 } }

    // MARK: - Preview

    /// Shows the camera in the app's UIKit preview layer and keeps it upright through the preview rotation
    /// angle. Call on the main actor after (or before) `start()`. The layer's own mirroring for the front
    /// camera is left automatic, which is what the PoseFrame mirroring assumes.
    @MainActor
    public func connectPreview(to layer: AVCaptureVideoPreviewLayer) {
        let binding = PreviewBinding(layer: layer) { [weak self] angle in
            self?.previewAngle.withLock { $0 = angle }
        }
        previewBinding = binding
        let box = UncheckedSendable(session)
        binding.attach(session: box.value, device: activeDevice.withLock { $0?.value })
    }

    @MainActor
    public func disconnectPreview() {
        previewBinding?.detach()
        previewBinding = nil
        previewAngle.withLock { $0 = nil }
    }

    private func rebindPreview() async {
        let box = UncheckedSendable(activeDevice.withLock { $0?.value })
        await MainActor.run { self.previewBinding?.rebind(device: box.value) }
    }

    // MARK: - Session queue work

    private func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    private func onSessionQueue(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                work()
                continuation.resume()
            }
        }
    }

    private func configureIfNeededAndStart() throws {
        guard !finished else { throw CameraError.finished }
        if !configured {
            // Center Stage crops and pans the image to follow the subject: the skeleton would move with it.
            // Take control of the feature and turn it off before any device input is created.
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false
            try configureOutputIfNeeded()
            try configureInput(restartObservers: false)
            configured = true
        }
        if !session.isRunning {
            session.startRunning()
        }
        refreshFeatureState()
        if let info = camera.withLock({ $0 }) { eventContinuation.yield(.started(info)) }
    }

    private func configureOutputIfNeeded() throws {
        guard !outputConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)
        output.alwaysDiscardsLateVideoFrames = true
        // The data output feeds the pose stream from the first frame; defer nothing here.
        if output.isDeferredStartSupported { output.isDeferredStartEnabled = false }
        let sampleDelegate = SampleDelegate(owner: self)
        delegate = sampleDelegate
        output.setSampleBufferDelegate(sampleDelegate, queue: videoQueue)
        session.commitConfiguration()
        observeSession()
        outputConfigured = true
    }

    /// Picks the camera, adds its input, selects the format and frame rate, fixes connection geometry and
    /// (re)starts the observers tied to the device.
    private func configureInput(restartObservers: Bool) throws {
        guard let chosen = Self.chooseDevice(position: wantedPosition, preferredID: configuration.preferredCameraID) else {
            throw CameraError.noCamera
        }
        if restartObservers { stopDeviceObservers() }

        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: chosen)
        } catch {
            session.commitConfiguration()
            throw CameraError.configurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(newInput) else {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(newInput)
        input = newInput
        device = chosen
        activeDevice.withLock { $0 = UncheckedSendable(chosen) }

        do {
            try applyFormat(to: chosen)
        } catch {
            session.commitConfiguration()
            throw CameraError.configurationFailed(error.localizedDescription)
        }

        // Buffers come in the sensor's native orientation and unmirrored: Vision gets the rotation as an
        // orientation, and x is mirrored in PoseFrame space. An explicit rotation of 0 also avoids the
        // default 180 degrees some iPad front cameras apply.
        if let connection = output.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            // Stabilization crops and warps the picture, and the skeleton would no longer sit on the preview.
            // It is off by default; say so, because the connection is made anew for every camera.
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
        }
        session.commitConfiguration()
        tracking.withLock { $0.reset() }

        let position: CameraPosition = chosen.position == .front ? .front : .back
        capture.withLock { $0.mirrored = chosen.position == .front }
        let info = Self.info(for: chosen)
        camera.withLock { $0 = info }
        metrics.withLock { $0.cameraName = info.name }
        log.info("camera selected: \(info.name, privacy: .public) [\(info.deviceType, privacy: .public)] id \(info.id, privacy: .public) as \(position.rawValue, privacy: .public)")

        startDeviceObservers(for: chosen)
        if restartObservers { eventContinuation.yield(.cameraChanged(info)) }
    }

    private func applyFormat(to device: AVCaptureDevice) throws {
        let candidates = device.formats.map { format -> CaptureFormatCandidate in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            return CaptureFormatCandidate(
                width: Int(dimensions.width), height: Int(dimensions.height),
                frameRateRanges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate },
                isBinned: format.isVideoBinned,
                supportsCenterStage: format.isCenterStageSupported,
                isBiPlanar420: subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                    || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            )
        }
        guard let index = CaptureFormatChoice.best(
            of: candidates, frameRate: configuration.frameRate, preferredHeight: configuration.preferredHeight
        ) else {
            throw CameraError.configurationFailed("no \(Int(configuration.frameRate)) fps 4:2:0 format near \(configuration.preferredHeight)p")
        }
        let format = device.formats[index]
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = format
        let candidate = candidates[index]
        metrics.withLock {
            $0.format = "\(candidate.width)x\(candidate.height)\(candidate.isBinned ? " binned" : "")"
        }
        try setFrameRate(configuration.frameRate, on: device, locked: true)
    }

    /// Sets min and max frame duration (a fixed rate), clamped into what the active format supports.
    private func setFrameRate(_ wanted: Double, on device: AVCaptureDevice, locked: Bool = false) throws {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
        let rate = CaptureFormatChoice.clamp(frameRate: wanted, to: ranges)
        if !locked { try device.lockForConfiguration() }
        defer { if !locked { device.unlockForConfiguration() } }
        let duration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        metrics.withLock { $0.targetFrameRate = rate }
    }

    /// Records whether Center Stage and stabilization are really off, for the HUD: a device check cannot
    /// trust that the settings above took effect.
    private func refreshFeatureState() {
        let centerStage = device?.isCenterStageActive ?? false
        let stabilization = output.connection(with: .video).map { $0.activeVideoStabilizationMode != .off } ?? false
        metrics.withLock {
            $0.centerStageActive = centerStage
            $0.stabilizationActive = stabilization
        }
        if centerStage { log.error("Center Stage is active; the skeleton will not follow the preview") }
        if stabilization { log.error("video stabilization is active; the skeleton will not follow the preview") }
    }

    // MARK: - Observers

    private func startDeviceObservers(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        // The coordinator reports the angle that makes the unrotated buffer upright for capture. KVO
        // callbacks arrive on the main queue; the value is only copied into the lock-protected parameters.
        let rotation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = Double(coordinator.videoRotationAngleForHorizonLevelCapture)
            self?.capture.withLock {
                $0.angle = angle
                $0.orientation = PoseGeometry.orientation(rotationAngle: angle)
            }
        }
        let centerStage = device.observe(\.isCenterStageActive, options: [.new]) { [weak self] device, _ in
            let active = device.isCenterStageActive
            self?.metrics.withLock { $0.centerStageActive = active }
        }
        let pressure = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] device, _ in
            guard let self else { return }
            let level = Self.pressure(from: device.systemPressureState.level)
            let observed = UncheckedSendable(device)
            sessionQueue.async { self.pressureChanged(to: level, device: observed.value) }
        }
        observations += [rotation, pressure, centerStage]
    }

    private func stopDeviceObservers() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        rotationCoordinator = nil
    }

    private func pressureChanged(to level: CapturePressure, device: AVCaptureDevice) {
        guard !finished, device === self.device else { return }
        let rate = level.frameRate(nominal: configuration.frameRate)
        let previous = metrics.withLock { m -> CapturePressure in
            let old = m.pressure
            m.pressure = level
            return old
        }
        do {
            try setFrameRate(rate, on: device)
        } catch {
            log.error("could not change frame rate: \(error.localizedDescription, privacy: .public)")
        }
        guard level != previous else { return }
        log.notice("system pressure \(String(describing: level), privacy: .public): \(rate) fps")
        eventContinuation.yield(.pressure(level, frameRate: rate))
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let interrupted = center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)).map(Self.describe) ?? "unknown"
            self?.eventContinuation.yield(.interrupted(reason: reason))
        }
        let resumed = center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            self?.eventContinuation.yield(.interruptionEnded)
        }
        let failed = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? AVError
            let message = error?.localizedDescription ?? "unknown error"
            log.error("capture runtime error: \(message, privacy: .public)")
            self?.eventContinuation.yield(.runtimeError(message))
            // After a media services reset the session must be started again.
            if error?.code == .mediaServicesWereReset, let self {
                sessionQueue.async {
                    guard !self.finished, !self.session.isRunning else { return }
                    self.session.startRunning()
                }
            }
        }
        notificationTokens = [interrupted, resumed, failed]
    }

    private func shutDown() {
        guard !finished else { return }
        finished = true
        stopDeviceObservers()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
        eventContinuation.yield(.stopped)
        frameContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: - Frames (video queue)

    fileprivate func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time.isFinite else { return }      // an invalid timestamp would break the recorder and the clock
        let parameters = capture.withLock { $0 }
        let estimate = estimator.measureBlocking(
            pixelBuffer: pixelBuffer, orientation: parameters.orientation, mirrored: parameters.mirrored, time: time
        )
        let frame: PoseFrame
        if let estimate {
            frame = tracking.withLock { estimate.frame(following: &$0) }
            metrics.withLock {
                $0.processed += 1
                if !frame.joints.isEmpty { $0.withPerson += 1 }
                $0.latencies.record(estimate.visionSeconds)
                $0.meter.record(time)
            }
        } else {
            // Vision failed or timed out: say "nobody" for this instant and count it.
            frame = PoseFrame(
                t: time, joints: [:],
                imageAspect: PoseGeometry.imageAspect(
                    pixelWidth: CVPixelBufferGetWidth(pixelBuffer), pixelHeight: CVPixelBufferGetHeight(pixelBuffer),
                    orientation: parameters.orientation
                )
            )
            metrics.withLock {
                $0.failures += 1
                $0.meter.record(time)
            }
        }
        frameContinuation.yield(frame)
    }

    fileprivate func noteDropped() {
        metrics.withLock { $0.dropped += 1 }
    }

    // MARK: - Discovery

    private static func discover(position: CameraPosition) -> [AVCaptureDevice] {
        let avPosition: AVCaptureDevice.Position = position == .back ? .back : .front
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTrueDepthCamera]
        if #available(iOS 27.1, *) {
            // The foldable's outer and inner (under-display) cameras.
            types += [.builtInOuterUltraWideCamera, .builtInInnerUltraWideCamera]
        }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: avPosition).devices
    }

    /// The standard wide camera of a position; any camera of that position if there is no wide one. A
    /// preferred id wins when it exists.
    private static func chooseDevice(position: CameraPosition, preferredID: String?) -> AVCaptureDevice? {
        let devices = discover(position: position)
        for device in devices {
            log.info("found \(position.rawValue, privacy: .public) camera: \(device.localizedName, privacy: .public) [\(device.deviceType.rawValue, privacy: .public)] id \(device.uniqueID, privacy: .public)")
        }
        if let preferredID, let match = devices.first(where: { $0.uniqueID == preferredID }) { return match }
        return devices.first { $0.deviceType == .builtInWideAngleCamera }
            ?? devices.first { $0.deviceType == .builtInTrueDepthCamera }
            ?? devices.first
    }

    private static func info(for device: AVCaptureDevice) -> CameraInfo {
        CameraInfo(
            id: device.uniqueID, name: device.localizedName, deviceType: device.deviceType.rawValue,
            position: device.position == .front ? .front : .back
        )
    }

    private static func pressure(from level: AVCaptureDevice.SystemPressureState.Level) -> CapturePressure {
        switch level {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        case .shutdown: .shutdown
        default: .fair
        }
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: "camera not available in the background"
        case .audioDeviceInUseByAnotherClient: "audio device in use"
        case .videoDeviceInUseByAnotherClient: "camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "camera not available with several foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure: "system pressure"
        case .sensitiveContentMitigationActivated: "sensitive content mitigation"
        @unknown default: "unknown"
        }
    }
}

// MARK: - Sample buffer delegate

/// Receives frames on the video queue and forwards them to the pipeline.
private final class SampleDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private weak var owner: CameraPipeline?

    init(owner: CameraPipeline) {
        self.owner = owner
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        owner?.handle(sampleBuffer)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        owner?.noteDropped()
    }
}

// MARK: - Preview hookup

/// Ties an `AVCaptureVideoPreviewLayer` to the pipeline's session and keeps it upright with the preview
/// rotation angle of the current camera.
@MainActor
private final class PreviewBinding {
    private weak var layer: AVCaptureVideoPreviewLayer?
    private var coordinator: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?
    /// Told every angle the layer is rotated to.
    private let onAngle: @Sendable (Double) -> Void

    init(layer: AVCaptureVideoPreviewLayer, onAngle: @escaping @Sendable (Double) -> Void) {
        self.layer = layer
        self.onAngle = onAngle
    }

    func attach(session: AVCaptureSession, device: AVCaptureDevice?) {
        layer?.session = session
        rebind(device: device)
    }

    func rebind(device: AVCaptureDevice?) {
        observation = nil
        coordinator = nil
        guard let layer, let device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        self.coordinator = coordinator
        observation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            MainActor.assumeIsolated { self?.apply(angle) }
        }
    }

    func detach() {
        observation = nil
        coordinator = nil
        layer?.session = nil
    }

    private func apply(_ angle: CGFloat) {
        guard let connection = layer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        onAngle(Double(angle))
    }
}
#endif
