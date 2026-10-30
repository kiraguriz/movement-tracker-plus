import CoreGraphics
import Foundation
import ImageIO

// Platform-independent parts of the camera layer, so the decisions (which format, how fast under thermal
// pressure, how fps is measured) are unit-tested on macOS. `CameraPipeline` (iOS only) applies them.

/// What a capture format offers, in plain values.
public struct CaptureFormatCandidate: Equatable, Sendable {
    public var width: Int
    public var height: Int
    /// Supported frame-rate ranges, in frames per second.
    public var frameRateRanges: [ClosedRange<Double>]
    /// A binned sensor readout: less power and noise at the same resolution.
    public var isBinned: Bool
    public var supportsCenterStage: Bool
    /// Bi-planar 4:2:0 (video or full range), the format Vision reads without conversion.
    public var isBiPlanar420: Bool

    public init(
        width: Int, height: Int, frameRateRanges: [ClosedRange<Double>], isBinned: Bool,
        supportsCenterStage: Bool, isBiPlanar420: Bool
    ) {
        self.width = width
        self.height = height
        self.frameRateRanges = frameRateRanges
        self.isBinned = isBinned
        self.supportsCenterStage = supportsCenterStage
        self.isBiPlanar420 = isBiPlanar420
    }

    public func supports(frameRate: Double) -> Bool {
        frameRateRanges.contains { $0.contains(frameRate) }
    }
}

/// Picks the capture format for pose estimation: about 720p to 1080p at the wanted frame rate, binned if
/// possible (Vision resizes the frame anyway, so more pixels only cost power), 16:9, without Center Stage
/// cropping if a choice remains.
public enum CaptureFormatChoice {
    /// The index of the best candidate, or nil if none can deliver `frameRate` in 480 to 1440 pixel height.
    public static func best(
        of candidates: [CaptureFormatCandidate], frameRate: Double = 30, preferredHeight: Int = 720
    ) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, c) in candidates.enumerated() {
            guard c.isBiPlanar420, c.width >= c.height, c.supports(frameRate: frameRate),
                  (480...1440).contains(c.height) else { continue }
            var score = 1000 - Double(abs(c.height - preferredHeight))
            if c.isBinned { score += 300 }
            if !c.supportsCenterStage { score += 100 }
            if abs(Double(c.width) / Double(c.height) - 16.0 / 9.0) < 0.02 { score += 200 }
            if best == nil || score > best!.score { best = (index, score) }
        }
        return best?.index
    }

    /// The frame rate to ask a format for: `wanted`, moved into the nearest supported range.
    public static func clamp(frameRate wanted: Double, to ranges: [ClosedRange<Double>]) -> Double {
        guard !ranges.isEmpty else { return wanted }
        if ranges.contains(where: { $0.contains(wanted) }) { return wanted }
        let candidates = ranges.map { min(max(wanted, $0.lowerBound), $0.upperBound) }
        return candidates.min { abs($0 - wanted) < abs($1 - wanted) } ?? wanted
    }
}

/// How hot the device is, mirroring `AVCaptureDevice.SystemPressureState.Level`.
public enum CapturePressure: Int, Comparable, Sendable {
    case nominal, fair, serious, critical, shutdown

    public static func < (a: CapturePressure, b: CapturePressure) -> Bool { a.rawValue < b.rawValue }

    /// The frame rate to run at: full speed until `serious`, then lower to cool down (the engine is driven by
    /// frame time, so a lower rate costs smoothness, not correctness).
    public func frameRate(nominal: Double) -> Double {
        switch self {
        case .nominal, .fair: nominal
        case .serious: min(nominal, 20)
        case .critical, .shutdown: min(nominal, 15)
        }
    }
}

/// Delivered frames per second over the last `window` seconds of capture time.
public struct FrameRateMeter: Sendable {
    public let window: Double
    private var times: [Double] = []

    public init(window: Double = 1.0) {
        self.window = max(0.1, window)
    }

    public mutating func record(_ time: Double) {
        guard time.isFinite else { return }
        if let last = times.last, time < last { times.removeAll() }   // the clock restarted
        times.append(time)
        let cutoff = time - window
        if let firstKept = times.firstIndex(where: { $0 >= cutoff }), firstKept > 0 {
            times.removeFirst(firstKept)
        }
    }

    /// Frames per second, 0 until two frames are in the window.
    public var fps: Double {
        guard times.count >= 2, let first = times.first, let last = times.last, last > first else { return 0 }
        return Double(times.count - 1) / (last - first)
    }
}

/// A snapshot of the live camera numbers for the Day-0 gate HUD.
public struct CameraStats: Equatable, Sendable {
    /// Vision latency over the last 120 frames.
    public var visionLatency: LatencySummary
    /// Frames delivered to the stream per second (capture time).
    public var deliveredFPS: Double
    /// Frames the capture output dropped because processing was late.
    public var droppedFrames: Int
    public var framesProcessed: Int
    public var framesWithPerson: Int
    /// Frames where the Vision call failed or timed out.
    public var visionFailures: Int
    public var pressure: CapturePressure
    /// The frame rate currently requested from the camera.
    public var targetFrameRate: Double
    /// For example `1280x720 binned`.
    public var format: String
    public var cameraName: String
    /// The orientation passed to Vision and whether x is mirrored, for checking on a real device.
    public var orientation: CGImagePropertyOrientation
    public var isMirrored: Bool
    /// The capture rotation angle behind `orientation`, in degrees.
    public var captureRotationAngle: Double
    /// The angle the preview layer is rotated by; nil until a preview is connected.
    public var previewRotationAngle: Double?
    /// How far the overlay must be turned to sit on the preview (`OverlayMapping(quarterTurns:)`); nonzero
    /// when the preview and the frames are turned differently.
    public var overlayQuarterTurns: Int
    /// Center Stage is cropping and panning the picture (it must not: the skeleton would drift off the preview).
    public var centerStageActive: Bool
    /// Video stabilization is on (it must not be, for the same reason).
    public var stabilizationActive: Bool

    public static let empty = CameraStats(
        visionLatency: .empty, deliveredFPS: 0, droppedFrames: 0, framesProcessed: 0, framesWithPerson: 0,
        visionFailures: 0, pressure: .nominal, targetFrameRate: 0, format: "", cameraName: "",
        orientation: .up, isMirrored: false, captureRotationAngle: 0, previewRotationAngle: nil,
        overlayQuarterTurns: 0, centerStageActive: false, stabilizationActive: false
    )
}
