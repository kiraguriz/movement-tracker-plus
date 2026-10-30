import CoreGraphics
import Foundation
import ImageIO

/// Pure functions behind the PoseFrame coordinate convention.
///
/// **Convention (verified against Vision, see `VisionPoseEstimatorTests`).** When Vision is given an image
/// together with a `CGImagePropertyOrientation`, it reports joints in the normalized coordinates of the
/// *oriented* (upright) image: origin bottom-left, y up, x and y in 0...1 of the upright width and height.
/// This holds for all eight orientations and for pixel buffers and `CGImage`s alike. So the estimator
/// never rotates points itself; it only has to
///  1. pass the right orientation (`orientation(rotationAngle:)` for a camera, `orientation(preferredTransform:)`
///     for a video track),
///  2. mirror x when the preview is mirrored (front camera): `x' = 1 - x`,
///  3. report the aspect ratio of the *oriented* image (`imageAspect`).
public enum PoseGeometry {
    /// The pixel size of an image after `orientation` is applied: the four quarter-turn orientations
    /// swap width and height.
    public static func orientedSize(of size: CGSize, orientation: CGImagePropertyOrientation) -> CGSize {
        orientation.swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    /// Width divided by height of the upright image. Returns 1 for a degenerate size.
    public static func imageAspect(pixelWidth: Int, pixelHeight: Int, orientation: CGImagePropertyOrientation) -> Double {
        let size = orientedSize(of: CGSize(width: pixelWidth, height: pixelHeight), orientation: orientation)
        guard size.width > 0, size.height > 0 else { return 1 }
        return Double(size.width / size.height)
    }

    /// Turns a point from Vision's oriented-image space into PoseFrame space. A mirrored preview (front
    /// camera) flips x about the vertical axis; y is untouched. Coordinates are not clamped: Vision can
    /// place a joint slightly outside the frame and that information is kept.
    public static func poseCoordinates(x: Double, y: Double, mirrored: Bool) -> (x: Double, y: Double) {
        (mirrored ? 1 - x : x, y)
    }

    /// The orientation that makes a camera buffer upright for a given capture rotation angle, as reported
    /// by `AVCaptureDevice.RotationCoordinator.videoRotationAngleForHorizonLevelCapture` for a buffer in
    /// the sensor's native orientation: the angle is a clockwise rotation, so 90 degrees is `.right`
    /// (the iPhone portrait back camera). Angles snap to the nearest quarter turn; non-finite angles
    /// give `.up`. Mirroring is separate (`poseCoordinates`).
    public static func orientation(rotationAngle degrees: Double) -> CGImagePropertyOrientation {
        guard degrees.isFinite else { return .up }
        // Reduce first: a huge finite angle must not overflow the integer conversion.
        let turns = Int((degrees.truncatingRemainder(dividingBy: 360) / 90).rounded())
        switch ((turns % 4) + 4) % 4 {
        case 1: return .right
        case 2: return .down
        case 3: return .left
        default: return .up
        }
    }

    /// Quarter turns clockwise (0...3) that carry a `PoseFrame`'s picture onto the picture an
    /// `AVCaptureVideoPreviewLayer` shows, for `OverlayMapping(quarterTurns:)`.
    ///
    /// Vision gets the *capture* angle, the one that makes the buffer upright against gravity
    /// (`videoRotationAngleForHorizonLevelCapture`). The preview layer is rotated by the *preview* angle
    /// (`videoRotationAngleForHorizonLevelPreview`), which accounts for how the interface is turned on the
    /// screen. They are the same while the interface turns with the device. They differ by quarter turns
    /// when it does not, for example in an interface locked to portrait with the phone held in landscape:
    /// the preview then stays fixed to the phone while the frames stay upright, and the overlay has to be
    /// turned by the difference. The preview mirrors after it rotates, so a mirrored (front camera) pair
    /// differs by the opposite turn.
    public static func overlayQuarterTurns(captureAngle: Double, previewAngle: Double, mirrored: Bool) -> Int {
        func turns(_ degrees: Double) -> Int {
            guard degrees.isFinite else { return 0 }
            return Int((degrees.truncatingRemainder(dividingBy: 360) / 90).rounded())
        }
        let difference = (((turns(previewAngle) - turns(captureAngle)) % 4) + 4) % 4
        return mirrored ? (4 - difference) % 4 : difference
    }

    /// The orientation that makes a video track's frames upright, from its `preferredTransform`. The
    /// transform acts in a top-left-origin, y-down space: a portrait iPhone movie carries
    /// `(a: 0, b: 1, c: -1, d: 0)`, which is a 90 degree clockwise turn, `.right`. Transforms that are not
    /// a multiple of a quarter turn (with or without a flip) give `.up`.
    public static func orientation(preferredTransform t: CGAffineTransform) -> CGImagePropertyOrientation {
        let scale = max(abs(t.a), abs(t.b), abs(t.c), abs(t.d))
        guard scale > 0, scale.isFinite else { return .up }
        func unit(_ v: CGFloat) -> Int? {
            let n = v / scale
            if abs(n) < 0.01 { return 0 }
            if abs(n - 1) < 0.01 { return 1 }
            if abs(n + 1) < 0.01 { return -1 }
            return nil
        }
        guard let a = unit(t.a), let b = unit(t.b), let c = unit(t.c), let d = unit(t.d) else { return .up }
        switch (a, b, c, d) {
        case (1, 0, 0, 1): return .up
        case (-1, 0, 0, 1): return .upMirrored
        case (-1, 0, 0, -1): return .down
        case (1, 0, 0, -1): return .downMirrored
        case (0, 1, 1, 0): return .leftMirrored
        case (0, 1, -1, 0): return .right
        case (0, -1, -1, 0): return .rightMirrored
        case (0, -1, 1, 0): return .left
        default: return .up
        }
    }
}

extension CGImagePropertyOrientation {
    /// True for the four orientations that turn the image a quarter turn (width and height swap).
    var swapsAxes: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored: true
        case .up, .upMirrored, .down, .downMirrored: false
        @unknown default: false
        }
    }
}
