import CoreGraphics
import Foundation
import ImageIO
import MotionCore
import Testing
@testable import PoseCapture

/// The whole coordinate chain, checked against a model written from first principles (plain rotation
/// arithmetic on pixels, no EXIF table, no `OverlayMapping`): a point on the raw sensor buffer goes through
/// Vision (told the capture orientation), `PoseAssembly` (mirroring, aspect) and `OverlayMapping`, and has to
/// land exactly where an `AVCaptureVideoPreviewLayer` draws the same sensor point.
@Suite("Coordinates from sensor to overlay")
struct CoordinateChainTests {
    private let rawSize = CGSize(width: 1280, height: 720)

    /// A pixel of the raw buffer (origin top-left, y down) after the picture is turned clockwise by
    /// `degrees` about its centre: in the turned picture's own pixel space.
    private func rotated(_ p: CGPoint, by degrees: Double) -> (point: CGPoint, size: CGSize) {
        let radians = degrees * .pi / 180
        let swaps = Int((degrees / 90).rounded()) % 2 != 0
        let size = swaps ? CGSize(width: rawSize.height, height: rawSize.width) : rawSize
        let dx = p.x - rawSize.width / 2, dy = p.y - rawSize.height / 2
        // Clockwise on screen (y down) is the standard rotation matrix.
        let x = dx * cos(radians) - dy * sin(radians)
        let y = dx * sin(radians) + dy * cos(radians)
        return (CGPoint(x: size.width / 2 + x, y: size.height / 2 + y), size)
    }

    /// Where a preview layer rotated by `previewAngle`, mirrored or not, draws a raw pixel in a view.
    private func previewPoint(
        raw: CGPoint, previewAngle: Double, mirrored: Bool, viewSize: CGSize, gravity: OverlayMapping.Gravity
    ) -> CGPoint {
        let turned = rotated(raw, by: previewAngle)
        let x = mirrored ? turned.size.width - turned.point.x : turned.point.x
        let fill = max(viewSize.width / turned.size.width, viewSize.height / turned.size.height)
        let fit = min(viewSize.width / turned.size.width, viewSize.height / turned.size.height)
        let scale = switch gravity {
        case .aspectFill: fill
        case .aspectFit: fit
        case .stretch: 1.0
        }
        if gravity == .stretch {
            return CGPoint(x: x / turned.size.width * viewSize.width, y: turned.point.y / turned.size.height * viewSize.height)
        }
        return CGPoint(
            x: (viewSize.width - turned.size.width * scale) / 2 + x * scale,
            y: (viewSize.height - turned.size.height * scale) / 2 + turned.point.y * scale
        )
    }

    /// What the overlay draws for a raw pixel, going through Vision's convention, `PoseAssembly` and
    /// `OverlayMapping`.
    private func overlayPoint(
        raw: CGPoint, captureAngle: Double, previewAngle: Double, mirrored: Bool, viewSize: CGSize,
        gravity: OverlayMapping.Gravity
    ) throws -> CGPoint {
        // Vision, told the capture orientation, reports the point in the upright image, origin bottom-left.
        let upright = rotated(raw, by: captureAngle)
        let vision = VisionJointSample(x: Double(upright.point.x / upright.size.width), y: Double(1 - upright.point.y / upright.size.height), confidence: 0.9)
        let frame = PoseAssembly.frame(
            people: [[.nose: vision]], time: 1, pixelWidth: Int(rawSize.width), pixelHeight: Int(rawSize.height),
            orientation: PoseGeometry.orientation(rotationAngle: captureAngle), mirrored: mirrored
        )
        let nose = try #require(frame.joints[.nose])
        let mapping = OverlayMapping(
            viewSize: viewSize, imageAspect: frame.imageAspect, gravity: gravity,
            quarterTurns: PoseGeometry.overlayQuarterTurns(captureAngle: captureAngle, previewAngle: previewAngle, mirrored: mirrored)
        )
        return mapping.viewPoint(for: nose)
    }

    private let views = [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390), CGSize(width: 700, height: 720)]
    private let points = [CGPoint(x: 0, y: 0), CGPoint(x: 1280, y: 720), CGPoint(x: 256, y: 252), CGPoint(x: 900, y: 100)]
    private let angles = [0.0, 90, 180, 270]

    @Test("the overlay lands where the preview draws the sensor point", arguments: [0.0, 90, 180, 270], [false, true])
    func overlayMatchesThePreview(_ captureAngle: Double, _ mirrored: Bool) throws {
        for previewAngle in angles {
            for gravity in [OverlayMapping.Gravity.aspectFill, .aspectFit, .stretch] {
                for view in views {
                    for raw in points {
                        let expected = previewPoint(raw: raw, previewAngle: previewAngle, mirrored: mirrored, viewSize: view, gravity: gravity)
                        let actual = try overlayPoint(
                            raw: raw, captureAngle: captureAngle, previewAngle: previewAngle, mirrored: mirrored,
                            viewSize: view, gravity: gravity
                        )
                        #expect(
                            abs(actual.x - expected.x) < 1e-6 && abs(actual.y - expected.y) < 1e-6,
                            "capture \(captureAngle) preview \(previewAngle) mirrored \(mirrored) \(gravity) view \(view) raw \(raw): \(actual) vs \(expected)"
                        )
                    }
                }
            }
        }
    }

    @Test("a preview that turns with the device needs no overlay rotation", arguments: [0.0, 90, 180, 270], [false, true])
    func matchingAnglesNeedNoRotation(_ angle: Double, _ mirrored: Bool) {
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: angle, previewAngle: angle, mirrored: mirrored) == 0)
    }

    @Test func aPreviewFixedToThePhoneInLandscapeNeedsAQuarterTurn() {
        // Interface locked to portrait (preview angle 90, the portrait value), phone held in landscape (the
        // capture angle makes the sensor buffer upright against gravity: 0 or 180).
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: 0, previewAngle: 90, mirrored: false) == 1)
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: 0, previewAngle: 90, mirrored: true) == 3)
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: 180, previewAngle: 90, mirrored: false) == 3)
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: 180, previewAngle: 90, mirrored: true) == 1)
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: 270, previewAngle: 90, mirrored: false) == 2)
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: 270, previewAngle: 90, mirrored: true) == 2)
    }

    @Test func quarterTurnsIgnoreNonsenseAngles() {
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: .nan, previewAngle: 90, mirrored: false) == 1)
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: 90, previewAngle: .infinity, mirrored: false) == 3)
        #expect(PoseGeometry.overlayQuarterTurns(captureAngle: 450, previewAngle: -270, mirrored: false) == 0)
        _ = PoseGeometry.overlayQuarterTurns(captureAngle: 1e300, previewAngle: -1e300, mirrored: true)
    }

    // MARK: Mapping with rotation

    @Test("with quarter turns the view point and normalized point stay inverses", arguments: 0..<4)
    func rotatedRoundTrip(_ turns: Int) {
        for gravity in [OverlayMapping.Gravity.aspectFill, .aspectFit, .stretch] {
            let m = OverlayMapping(viewSize: CGSize(width: 390, height: 844), imageAspect: 16.0 / 9, gravity: gravity, quarterTurns: turns)
            for (x, y) in [(0.1, 0.2), (0.5, 0.5), (0.93, 0.07), (-0.05, 1.04)] {
                let back = m.normalizedPoint(for: m.viewPoint(x: x, y: y))
                #expect(abs(back.x - x) < 1e-9 && abs(back.y - y) < 1e-9, "turns \(turns) \(gravity)")
            }
        }
    }

    @Test("the visible rectangle is exactly what isVisible accepts", arguments: 0..<4)
    func rotatedVisibleRect(_ turns: Int) {
        let m = OverlayMapping(viewSize: CGSize(width: 390, height: 844), imageAspect: 16.0 / 9, gravity: .aspectFill, quarterTurns: turns)
        let rect = m.visibleNormalizedRect
        #expect(rect.width > 0 && rect.height > 0 && rect.minX >= 0 && rect.minY >= 0 && rect.maxX <= 1 && rect.maxY <= 1)
        let inset = 0.01
        // Just inside each edge of the rectangle is visible, just outside is not (unless the edge is the image's).
        for (x, y) in [
            (rect.minX + inset, rect.midY), (rect.maxX - inset, rect.midY), (rect.midX, rect.minY + inset), (rect.midX, rect.maxY - inset),
        ] {
            #expect(m.isVisible(x: x, y: y), "inside \(x),\(y) turns \(turns)")
        }
        for (x, y, atImageEdge) in [
            (rect.minX - inset, rect.midY, rect.minX <= 0), (rect.maxX + inset, rect.midY, rect.maxX >= 1),
            (rect.midX, rect.minY - inset, rect.minY <= 0), (rect.midX, rect.maxY + inset, rect.maxY >= 1),
        ] where !atImageEdge {
            #expect(!m.isVisible(x: x, y: y), "outside \(x),\(y) turns \(turns)")
        }
    }

    @Test func withOddTurnsTheShownPictureHasTheOppositeAspect() {
        let upright = OverlayMapping(viewSize: CGSize(width: 400, height: 400), imageAspect: 2, gravity: .aspectFit)
        let turned = OverlayMapping(viewSize: CGSize(width: 400, height: 400), imageAspect: 2, gravity: .aspectFit, quarterTurns: 1)
        #expect(upright.contentRect == CGRect(x: 0, y: 100, width: 400, height: 200))
        #expect(turned.contentRect == CGRect(x: 100, y: 0, width: 200, height: 400))
        #expect(OverlayMapping(viewSize: .zero, imageAspect: 2, gravity: .aspectFit, quarterTurns: -3).quarterTurns == 1)
    }
}
