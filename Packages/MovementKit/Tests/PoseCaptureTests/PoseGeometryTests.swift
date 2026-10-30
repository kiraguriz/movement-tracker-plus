import CoreGraphics
import Foundation
import ImageIO
import MotionCore
import Testing
@testable import PoseCapture

/// The EXIF orientation table written out independently of the implementation: where a point of the raw
/// image (normalized, origin top-left, y down) lies in the upright image. Orientation 1 to 8.
func exifUpright(_ p: CGPoint, _ orientation: CGImagePropertyOrientation) -> CGPoint {
    let (x, y) = (p.x, p.y)
    switch orientation {
    case .up: return CGPoint(x: x, y: y)
    case .upMirrored: return CGPoint(x: 1 - x, y: y)
    case .down: return CGPoint(x: 1 - x, y: 1 - y)
    case .downMirrored: return CGPoint(x: x, y: 1 - y)
    case .leftMirrored: return CGPoint(x: y, y: x)
    case .right: return CGPoint(x: 1 - y, y: x)
    case .rightMirrored: return CGPoint(x: 1 - y, y: 1 - x)
    case .left: return CGPoint(x: y, y: 1 - x)
    @unknown default: return p
    }
}

let allOrientations: [CGImagePropertyOrientation] = [
    .up, .upMirrored, .down, .downMirrored, .leftMirrored, .right, .rightMirrored, .left,
]

private func close(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1e-9) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

/// The eight orientation transforms as AVFoundation reports them for a track, in normalized units.
private let orientationTransforms: [(CGImagePropertyOrientation, CGAffineTransform)] = [
    (.up, CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)),
    (.upMirrored, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)),
    (.down, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1, ty: 1)),
    (.downMirrored, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 1)),
    (.leftMirrored, CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)),
    (.right, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)),
    (.rightMirrored, CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: 1, ty: 1)),
    (.left, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1)),
]

@Suite("Pose geometry")
struct PoseGeometryTests {
    // MARK: Sizes

    @Test("quarter-turn orientations swap width and height", arguments: allOrientations)
    func orientedSize(_ orientation: CGImagePropertyOrientation) {
        let raw = CGSize(width: 1280, height: 720)
        let swaps: Set<CGImagePropertyOrientation> = [.leftMirrored, .right, .rightMirrored, .left]
        let expected = swaps.contains(orientation) ? CGSize(width: 720, height: 1280) : raw
        #expect(PoseGeometry.orientedSize(of: raw, orientation: orientation) == expected)
    }

    @Test("image aspect comes from the oriented size", arguments: allOrientations)
    func imageAspect(_ orientation: CGImagePropertyOrientation) {
        let aspect = PoseGeometry.imageAspect(pixelWidth: 1280, pixelHeight: 720, orientation: orientation)
        let portrait: Set<CGImagePropertyOrientation> = [.leftMirrored, .right, .rightMirrored, .left]
        let expected = portrait.contains(orientation) ? 720.0 / 1280.0 : 1280.0 / 720.0
        #expect(abs(aspect - expected) < 1e-12)
    }

    @Test func degenerateSizeGivesAspectOne() {
        #expect(PoseGeometry.imageAspect(pixelWidth: 0, pixelHeight: 720, orientation: .up) == 1)
        #expect(PoseGeometry.imageAspect(pixelWidth: 1280, pixelHeight: 0, orientation: .right) == 1)
    }

    // MARK: Mirroring

    @Test func mirroringFlipsOnlyX() {
        let plain = PoseGeometry.poseCoordinates(x: 0.2, y: 0.7, mirrored: false)
        let mirrored = PoseGeometry.poseCoordinates(x: 0.2, y: 0.7, mirrored: true)
        #expect(plain.x == 0.2 && plain.y == 0.7)
        #expect(abs(mirrored.x - 0.8) < 1e-12 && mirrored.y == 0.7)
    }

    @Test func mirroringKeepsOutOfFramePoints() {
        // Vision can report a joint just outside the image; the information is kept, not clamped.
        let p = PoseGeometry.poseCoordinates(x: -0.04, y: 1.03, mirrored: true)
        #expect(abs(p.x - 1.04) < 1e-12 && abs(p.y - 1.03) < 1e-12)
    }

    @Test func mirroringTwiceIsIdentity() {
        let once = PoseGeometry.poseCoordinates(x: 0.31, y: 0.4, mirrored: true)
        let twice = PoseGeometry.poseCoordinates(x: once.x, y: once.y, mirrored: true)
        #expect(abs(twice.x - 0.31) < 1e-12)
    }

    // MARK: Capture rotation angle

    @Test("rotation angles map to orientations", arguments: [
        (0.0, CGImagePropertyOrientation.up), (90, .right), (180, .down), (270, .left),
        (360, .up), (-90, .left), (-180, .down), (450, .right), (89.2, .right), (181, .down), (-0.4, .up),
        (.nan, .up), (.infinity, .up), (-.infinity, .up),
        (1e300, .up), (-1e300, .up), (1e19, .left), (36_000_090, .right), (-36_000_090, .left),
    ] as [(Double, CGImagePropertyOrientation)])
    func rotationAngle(_ angle: Double, _ expected: CGImagePropertyOrientation) {
        #expect(PoseGeometry.orientation(rotationAngle: angle) == expected)
    }

    @Test("a capture rotation of θ turns the raw image clockwise by θ", arguments: [0.0, 90, 180, 270])
    func rotationAngleIsClockwise(_ degrees: Double) {
        // Raw point left of centre. Rotate it clockwise by θ about the centre in a y-down space, the way a
        // person turns a photo, and compare with what the chosen orientation does to it.
        let raw = CGPoint(x: 0.1, y: 0.5)
        let radians = degrees * .pi / 180
        let dx = raw.x - 0.5, dy = raw.y - 0.5
        let turned = CGPoint(
            x: 0.5 + dx * cos(radians) - dy * sin(radians),
            y: 0.5 + dx * sin(radians) + dy * cos(radians)
        )
        let orientation = PoseGeometry.orientation(rotationAngle: degrees)
        #expect(close(exifUpright(raw, orientation), turned), "angle \(degrees)")
    }

    @Test func portraitBackCameraPutsTheSensorLeftEdgeAtTheTop() {
        // The iPhone sensor buffer is landscape; held upright, its left edge is the top of the picture.
        let orientation = PoseGeometry.orientation(rotationAngle: 90)
        #expect(orientation == .right)
        let top = exifUpright(CGPoint(x: 0, y: 0.5), orientation)
        #expect(close(top, CGPoint(x: 0.5, y: 0)))
    }

    // MARK: Preferred transform

    @Test("preferred transform to orientation", arguments: orientationTransforms.indices)
    func preferredTransform(_ index: Int) {
        let (expected, transform) = orientationTransforms[index]
        #expect(PoseGeometry.orientation(preferredTransform: transform) == expected)
        // The transform really does what the orientation says to a normalized raw point.
        let raw = CGPoint(x: 0.2, y: 0.7)
        #expect(close(raw.applying(transform), exifUpright(raw, expected)), "\(expected)")
    }

    @Test("preferred transform ignores scale and translation in pixels", arguments: orientationTransforms.indices)
    func preferredTransformWithPixelUnits(_ index: Int) {
        let (expected, unit) = orientationTransforms[index]
        let pixels = CGAffineTransform(a: unit.a, b: unit.b, c: unit.c, d: unit.d, tx: unit.tx * 1080, ty: unit.ty * 1920)
        #expect(PoseGeometry.orientation(preferredTransform: pixels) == expected)
    }

    @Test func portraitIPhoneMovieTransformIsRight() {
        #expect(PoseGeometry.orientation(preferredTransform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)) == .right)
    }

    @Test func oddTransformsFallBackToUp() {
        #expect(PoseGeometry.orientation(preferredTransform: CGAffineTransform(rotationAngle: 0.5)) == .up)
        #expect(PoseGeometry.orientation(preferredTransform: .init(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)) == .up)
        #expect(PoseGeometry.orientation(preferredTransform: .init(a: .nan, b: 0, c: 0, d: 1, tx: 0, ty: 0)) == .up)
    }

    // MARK: Whole chain

    private func sample(_ x: Double, _ y: Double, _ c: Double = 0.9) -> VisionJointSample {
        VisionJointSample(x: x, y: y, confidence: c)
    }

    @Test("frames for every orientation, with and without mirroring", arguments: allOrientations, [false, true])
    func frameAssembly(_ orientation: CGImagePropertyOrientation, _ mirrored: Bool) throws {
        let frame = PoseAssembly.frame(
            people: [[.nose: sample(0.25, 0.9), .root: sample(0.4, 0.5)]], time: 12.5,
            pixelWidth: 1920, pixelHeight: 1080, orientation: orientation, mirrored: mirrored
        )
        let portrait: Set<CGImagePropertyOrientation> = [.leftMirrored, .right, .rightMirrored, .left]
        let expectedAspect = portrait.contains(orientation) ? 1080.0 / 1920.0 : 1920.0 / 1080.0
        #expect(abs(frame.imageAspect - expectedAspect) < 1e-12)
        #expect(frame.t == 12.5)
        let nose = try #require(frame.joints[.nose])
        let root = try #require(frame.joints[.root])
        // Vision's numbers are already upright; only the mirroring is applied.
        #expect(abs(nose.x - (mirrored ? 0.75 : 0.25)) < 1e-12 && abs(nose.y - 0.9) < 1e-12)
        #expect(abs(root.x - (mirrored ? 0.6 : 0.4)) < 1e-12 && abs(root.y - 0.5) < 1e-12)
        #expect(nose.confidence == 0.9)
    }

    @Test func frontCameraPortraitEndToEnd() throws {
        // A front camera held upright: buffer 1920x1080 landscape, rotation 90 degrees, preview mirrored.
        // A person standing on the left of the picture the user sees ends up on the left in the frame.
        let orientation = PoseGeometry.orientation(rotationAngle: 90)
        let frame = PoseAssembly.frame(
            people: [[.nose: sample(0.7, 0.8)]], time: 1, pixelWidth: 1920, pixelHeight: 1080,
            orientation: orientation, mirrored: true
        )
        // Vision saw her at x 0.7 in the unmirrored upright image; the mirrored preview shows her at 0.3.
        let nose = try #require(frame.joints[.nose])
        #expect(abs(nose.x - 0.3) < 1e-12)
        #expect(abs(frame.imageAspect - 0.5625) < 1e-12)
    }
}
