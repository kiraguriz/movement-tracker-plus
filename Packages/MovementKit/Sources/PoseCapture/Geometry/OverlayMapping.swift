import CoreGraphics
import Foundation
import MotionCore

/// Maps PoseFrame coordinates (normalized, origin bottom-left, y up, already mirrored like the preview)
/// into a view, for the skeleton overlay. Results are in view coordinates with the origin at the
/// top-left and y down, as UIKit and Core Animation use. Pure and cheap: build one per layout change
/// and reuse it for every frame.
///
/// The camera image is assumed to fill the view the way an `AVCaptureVideoPreviewLayer` with the matching
/// `videoGravity` fills its bounds: `.resizeAspectFill` is `.aspectFill`, `.resizeAspect` is `.aspectFit`,
/// `.resize` is `.stretch`.
///
/// The preview shows the same picture the frames describe unless the interface is not turned with the
/// device; `quarterTurns` (`CameraPipeline.overlayQuarterTurns`) carries the frame's picture onto the
/// preview's in that case. Rebuild the mapping when the view size, a frame's `imageAspect` or the quarter
/// turns change.
public struct OverlayMapping: Equatable, Sendable {
    public enum Gravity: Sendable, Equatable {
        /// The image covers the view, centered; the overflow is cropped.
        case aspectFill
        /// The whole image is visible, centered, with bars on one axis.
        case aspectFit
        /// The image is stretched to the view.
        case stretch
    }

    public let viewSize: CGSize
    /// Width divided by height of the upright image (`PoseFrame.imageAspect`).
    public let imageAspect: Double
    public let gravity: Gravity
    /// Clockwise quarter turns (0...3) from the frame's picture to the picture the preview shows.
    public let quarterTurns: Int
    /// Where the whole preview picture lies in view coordinates. For `.aspectFill` it extends beyond the view.
    public let contentRect: CGRect

    public init(viewSize: CGSize, imageAspect: Double, gravity: Gravity, quarterTurns: Int = 0) {
        self.viewSize = viewSize
        self.imageAspect = imageAspect
        self.gravity = gravity
        let turns = ((quarterTurns % 4) + 4) % 4
        self.quarterTurns = turns
        let valid = viewSize.width > 0 && viewSize.height > 0 && imageAspect > 0 && imageAspect.isFinite
        guard valid else {
            contentRect = CGRect(origin: .zero, size: viewSize)
            return
        }
        // A quarter turn swaps the sides of the picture the preview shows.
        let shownAspect = turns % 2 == 0 ? imageAspect : 1 / imageAspect
        let width = Double(viewSize.width), height = Double(viewSize.height)
        let viewAspect = width / height
        var w = width, h = height
        switch gravity {
        case .stretch:
            break
        case .aspectFill:
            if shownAspect > viewAspect { w = height * shownAspect } else { h = width / shownAspect }
        case .aspectFit:
            if shownAspect > viewAspect { h = width / shownAspect } else { w = height * shownAspect }
        }
        contentRect = CGRect(x: (width - w) / 2, y: (height - h) / 2, width: w, height: h)
    }

    /// A normalized point (x right, y up) turned clockwise by `quarterTurns` quarter turns about the centre.
    private static func rotate(_ x: Double, _ y: Double, quarterTurns: Int) -> (x: Double, y: Double) {
        switch quarterTurns {
        case 1: (y, 1 - x)
        case 2: (1 - x, 1 - y)
        case 3: (1 - y, x)
        default: (x, y)
        }
    }

    /// The view point of a normalized pose point (x right, y up).
    public func viewPoint(x: Double, y: Double) -> CGPoint {
        let p = Self.rotate(x, y, quarterTurns: quarterTurns)
        return CGPoint(x: contentRect.minX + p.x * contentRect.width, y: contentRect.minY + (1 - p.y) * contentRect.height)
    }

    public func viewPoint(for keypoint: Keypoint) -> CGPoint {
        viewPoint(x: keypoint.x, y: keypoint.y)
    }

    /// The inverse: the normalized pose point under a view point (for hit tests and framing guides).
    public func normalizedPoint(for viewPoint: CGPoint) -> (x: Double, y: Double) {
        guard contentRect.width > 0, contentRect.height > 0 else { return (0, 0) }
        let shown = (
            x: Double((viewPoint.x - contentRect.minX) / contentRect.width),
            y: 1 - Double((viewPoint.y - contentRect.minY) / contentRect.height)
        )
        return Self.rotate(shown.x, shown.y, quarterTurns: (4 - quarterTurns) % 4)
    }

    /// The part of the image that is visible, in normalized pose coordinates (origin bottom-left).
    /// The whole image for `.aspectFit` and `.stretch`; the central crop for `.aspectFill`.
    public var visibleNormalizedRect: CGRect {
        guard contentRect.width > 0, contentRect.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let left = max(0, (0 - contentRect.minX) / contentRect.width)
        let right = min(1, (viewSize.width - contentRect.minX) / contentRect.width)
        let top = max(0, (0 - contentRect.minY) / contentRect.height)       // fraction cut from the top
        let bottom = min(1, (viewSize.height - contentRect.minY) / contentRect.height)
        // That is the visible part of the preview picture; carry its corners back to the frame's picture.
        let back = (4 - quarterTurns) % 4
        let a = Self.rotate(left, 1 - bottom, quarterTurns: back)
        let b = Self.rotate(right, 1 - top, quarterTurns: back)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// True when a normalized pose point is inside the visible part of the image.
    public func isVisible(x: Double, y: Double) -> Bool {
        let p = viewPoint(x: x, y: y)
        return p.x >= 0 && p.x <= viewSize.width && p.y >= 0 && p.y <= viewSize.height
    }

    /// View points of every joint at or above `minimumConfidence`.
    public func viewPoints(for frame: PoseFrame, minimumConfidence: Double = 0) -> [Joint: CGPoint] {
        var points: [Joint: CGPoint] = [:]
        points.reserveCapacity(frame.joints.count)
        for (joint, keypoint) in frame.joints where keypoint.confidence >= minimumConfidence {
            points[joint] = viewPoint(for: keypoint)
        }
        return points
    }

    /// One drawable bone.
    public struct BoneSegment: Equatable, Sendable {
        public var bone: Bone
        public var from: CGPoint
        public var to: CGPoint
    }

    /// The bones whose two joints are both at or above `minimumConfidence`, in `Skeleton.bones` order,
    /// ready for a `CAShapeLayer` path or a SwiftUI `Canvas`.
    public func boneSegments(for frame: PoseFrame, minimumConfidence: Double = 0.3) -> [BoneSegment] {
        var segments: [BoneSegment] = []
        segments.reserveCapacity(Skeleton.bones.count)
        for bone in Skeleton.bones {
            guard let a = frame.joints[bone.from], let b = frame.joints[bone.to],
                  a.confidence >= minimumConfidence, b.confidence >= minimumConfidence else { continue }
            segments.append(BoneSegment(bone: bone, from: viewPoint(for: a), to: viewPoint(for: b)))
        }
        return segments
    }
}
