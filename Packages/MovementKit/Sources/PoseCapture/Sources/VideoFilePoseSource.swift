import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import MotionCore
import Synchronization

/// Facts about a video file's first video track.
public struct VideoInfo: Equatable, Sendable {
    public var duration: TimeInterval
    /// Stored pixel size, before the preferred transform.
    public var pixelSize: CGSize
    /// The orientation the track's `preferredTransform` asks for.
    public var orientation: CGImagePropertyOrientation
    /// Width over height of the upright image (what `PoseFrame.imageAspect` will be).
    public var imageAspect: Double
    public var nominalFrameRate: Double
}

/// Reads a movie with `AVAssetReader` and turns every (or every 30 fps-th) frame into a `PoseFrame`:
/// frame time is the presentation time in seconds; the track's `preferredTransform` decides the
/// orientation passed to Vision, so a portrait iPhone movie comes out upright. When several people are in
/// view, a `PersonTracker` keeps following the same one. Frames where Vision finds nobody are delivered with
/// no joints, so the timeline stays continuous.
///
/// Per-frame Vision latency is collected for the Day-0 style report (`latency`). Run one `frames()`
/// stream at a time per source; a new call resets the statistics.
public final class VideoFilePoseSource: Sendable {
    public struct Options: Equatable, Sendable {
        /// Frames are skipped so that at most this many per second are processed. Nil processes every frame.
        public var maxFrameRate: Double? = 30
        /// Mirror x like a front-camera preview. Recorded files are normally not mirrored.
        public var mirrored = false
        /// Stop after this many delivered frames.
        public var maxFrames: Int?

        public init(maxFrameRate: Double? = 30, mirrored: Bool = false, maxFrames: Int? = nil) {
            self.maxFrameRate = maxFrameRate
            self.mirrored = mirrored
            self.maxFrames = maxFrames
        }
    }

    public enum SourceError: Error, Equatable, LocalizedError, Sendable {
        case noVideoTrack
        case readerFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The file has no video track."
            case let .readerFailed(reason): "The video could not be read: \(reason)"
            }
        }
    }

    private struct Stats: Sendable {
        var latencies: [Double] = []
        var framesDelivered = 0
        var framesWithPerson = 0
        var framesSkipped = 0
        var visionFailures = 0
    }

    public let url: URL
    public let options: Options
    private let estimator: VisionPoseEstimator
    private let stats = Mutex(Stats())

    public init(url: URL, estimator: VisionPoseEstimator = VisionPoseEstimator(), options: Options = Options()) {
        self.url = url
        self.estimator = estimator
        self.options = options
    }

    // MARK: - Statistics

    /// Seconds Vision spent on each processed frame, in order.
    public var latencies: [Double] { stats.withLock { $0.latencies } }
    public var latency: LatencySummary { LatencySummary(samples: latencies) }
    public var framesDelivered: Int { stats.withLock { $0.framesDelivered } }
    public var framesWithPerson: Int { stats.withLock { $0.framesWithPerson } }
    /// Frames the reader produced but the frame-rate limit skipped.
    public var framesSkipped: Int { stats.withLock { $0.framesSkipped } }
    public var visionFailures: Int { stats.withLock { $0.visionFailures } }

    // MARK: - Info

    public func info() async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SourceError.noVideoTrack }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let orientation = PoseGeometry.orientation(preferredTransform: transform)
        return VideoInfo(
            duration: duration.isNumeric ? duration.seconds : 0,
            pixelSize: size,
            orientation: orientation,
            imageAspect: PoseGeometry.imageAspect(
                pixelWidth: Int(size.width.rounded()), pixelHeight: Int(size.height.rounded()), orientation: orientation
            ),
            nominalFrameRate: Double(rate)
        )
    }

    // MARK: - Frames

    /// Starts reading. The stream ends when the file does, or throws if it cannot be read. Cancelling the
    /// consuming task stops the reader.
    public func frames() -> AsyncThrowingStream<PoseFrame, any Error> {
        stats.withLock { $0 = Stats() }
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    try await self.read(into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func read(into continuation: AsyncThrowingStream<PoseFrame, any Error>.Continuation) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SourceError.noVideoTrack }
        let transform = try await track.load(.preferredTransform)
        let orientation = PoseGeometry.orientation(preferredTransform: transform)

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw SourceError.readerFailed(error.localizedDescription)
        }
        // The camera delivers bi-planar 4:2:0; decode to the same format so timings are comparable.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        ])
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            throw SourceError.readerFailed(reader.error?.localizedDescription ?? error.localizedDescription)
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let minInterval = options.maxFrameRate.flatMap { $0 > 0 ? 1 / $0 : nil }
        var lastAccepted = -Double.infinity
        var lastTime = -Double.infinity
        var tracker = PersonTracker()

        while !Task.isCancelled, let sample = try await next(from: provider, reader: reader) {
            let image = sample.withUnsafeSampleBuffer { UncheckedSendable(CMSampleBufferGetImageBuffer($0)) }
            guard let pixelBuffer = image.value else { continue }
            let pts = sample.presentationTimeStamp.seconds
            guard pts.isFinite, pts > lastTime else { continue }
            lastTime = pts
            if let minInterval, pts - lastAccepted < minInterval * 0.8 {
                stats.withLock { $0.framesSkipped += 1 }
                continue
            }
            lastAccepted = pts

            let frame: PoseFrame
            do {
                let estimate = try await estimator.measure(
                    pixelBuffer: pixelBuffer, orientation: orientation, mirrored: options.mirrored, time: pts
                )
                frame = estimate.frame(following: &tracker)
                stats.withLock {
                    $0.latencies.append(estimate.visionSeconds)
                    if !frame.joints.isEmpty { $0.framesWithPerson += 1 }
                }
            } catch {
                // One bad frame must not end the file: deliver "nobody" and count the failure.
                stats.withLock { $0.visionFailures += 1 }
                frame = PoseFrame(
                    t: pts, joints: [:],
                    imageAspect: PoseGeometry.imageAspect(
                        pixelWidth: CVPixelBufferGetWidth(pixelBuffer), pixelHeight: CVPixelBufferGetHeight(pixelBuffer),
                        orientation: orientation
                    )
                )
            }
            continuation.yield(frame)
            let delivered = stats.withLock { stats -> Int in
                stats.framesDelivered += 1
                return stats.framesDelivered
            }
            if let maxFrames = options.maxFrames, delivered >= maxFrames { return }
        }

        if reader.status == .failed {
            throw SourceError.readerFailed(reader.error?.localizedDescription ?? "unknown error")
        }
    }

    private func next(
        from provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>, reader: AVAssetReader
    ) async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
        do {
            return try await provider.next()
        } catch {
            throw SourceError.readerFailed(reader.error?.localizedDescription ?? error.localizedDescription)
        }
    }
}
