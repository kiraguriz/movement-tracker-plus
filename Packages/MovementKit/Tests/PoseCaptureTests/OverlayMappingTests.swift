import CoreGraphics
import Foundation
import MotionCore
import Testing
@testable import PoseCapture

private func expectClose(_ a: CGPoint, _ b: CGPoint, tolerance: Double = 1e-9, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(abs(Double(a.x - b.x)) < tolerance && abs(Double(a.y - b.y)) < tolerance, "\(a) vs \(b)", sourceLocation: sourceLocation)
}

@Suite("Overlay mapping")
struct OverlayMappingTests {
    // A 9:16 portrait camera image on a 390x844 phone screen: the image is a little wider than the view
    // (390/844 = 0.462 < 0.5625), so aspect-fill crops the sides.
    private let phone = CGSize(width: 390, height: 844)

    @Test func aspectFillPortraitCropsTheSides() {
        let m = OverlayMapping(viewSize: phone, imageAspect: 9.0 / 16, gravity: .aspectFill)
        let height = 844.0
        let width = height * 9 / 16
        #expect(abs(m.contentRect.height - height) < 1e-9)
        #expect(abs(m.contentRect.width - width) < 1e-9)
        #expect(abs(m.contentRect.minX - (390 - width) / 2) < 1e-9)
        #expect(m.contentRect.minY == 0)
        // Image centre is the view centre.
        expectClose(m.viewPoint(x: 0.5, y: 0.5), CGPoint(x: 195, y: 422))
    }

    @Test func aspectFillLandscapeOnPortraitViewCropsMoreOfTheSides() {
        let m = OverlayMapping(viewSize: phone, imageAspect: 16.0 / 9, gravity: .aspectFill)
        #expect(abs(m.contentRect.height - 844) < 1e-9)
        #expect(abs(m.contentRect.width - 844 * 16 / 9) < 1e-9)
        let visible = m.visibleNormalizedRect
        #expect(abs(visible.width - 390.0 / (844 * 16 / 9)) < 1e-9)
        #expect(abs(visible.minX - (1 - visible.width) / 2) < 1e-9)
        #expect(visible.minY == 0 && visible.height == 1)
    }

    @Test func aspectFillWideImageOnWideViewCropsTopAndBottom() {
        let m = OverlayMapping(viewSize: CGSize(width: 800, height: 400), imageAspect: 1, gravity: .aspectFill)
        #expect(m.contentRect == CGRect(x: 0, y: -200, width: 800, height: 800))
        let visible = m.visibleNormalizedRect
        #expect(abs(visible.minY - 0.25) < 1e-9 && abs(visible.height - 0.5) < 1e-9)
        #expect(visible.minX == 0 && visible.width == 1)
    }

    @Test func aspectFitLeavesBars() {
        let m = OverlayMapping(viewSize: phone, imageAspect: 16.0 / 9, gravity: .aspectFit)
        #expect(abs(m.contentRect.width - 390) < 1e-9)
        #expect(abs(m.contentRect.height - 390 * 9 / 16) < 1e-9)
        #expect(abs(m.contentRect.midY - 422) < 1e-9)
        #expect(m.visibleNormalizedRect == CGRect(x: 0, y: 0, width: 1, height: 1))
        let pillar = OverlayMapping(viewSize: CGSize(width: 800, height: 400), imageAspect: 0.5, gravity: .aspectFit)
        #expect(pillar.contentRect == CGRect(x: 300, y: 0, width: 200, height: 400))
    }

    @Test func stretchFillsTheView() {
        let m = OverlayMapping(viewSize: phone, imageAspect: 16.0 / 9, gravity: .stretch)
        #expect(m.contentRect == CGRect(origin: .zero, size: phone))
    }

    @Test("y is flipped: the pose origin is bottom-left, the view origin top-left", arguments: [
        OverlayMapping.Gravity.aspectFill, .aspectFit, .stretch,
    ])
    func yFlip(_ gravity: OverlayMapping.Gravity) {
        let m = OverlayMapping(viewSize: CGSize(width: 400, height: 400), imageAspect: 1, gravity: gravity)
        expectClose(m.viewPoint(x: 0, y: 0), CGPoint(x: 0, y: 400))
        expectClose(m.viewPoint(x: 1, y: 1), CGPoint(x: 400, y: 0))
        expectClose(m.viewPoint(x: 0.25, y: 0.75), CGPoint(x: 100, y: 100))
    }

    @Test("view point and normalized point are inverses", arguments: [
        OverlayMapping.Gravity.aspectFill, .aspectFit, .stretch,
    ])
    func roundTrip(_ gravity: OverlayMapping.Gravity) {
        let m = OverlayMapping(viewSize: phone, imageAspect: 9.0 / 16, gravity: gravity)
        for (x, y) in [(0.1, 0.2), (0.5, 0.5), (0.93, 0.07), (-0.05, 1.04)] {
            let p = m.viewPoint(x: x, y: y)
            let back = m.normalizedPoint(for: p)
            #expect(abs(back.x - x) < 1e-9 && abs(back.y - y) < 1e-9)
        }
    }

    @Test func visibilityFollowsTheCrop() {
        let m = OverlayMapping(viewSize: phone, imageAspect: 16.0 / 9, gravity: .aspectFill)
        #expect(m.isVisible(x: 0.5, y: 0.5))
        #expect(!m.isVisible(x: 0.02, y: 0.5))     // cropped away on the left
        #expect(!m.isVisible(x: 0.5, y: 1.1))      // above the image
    }

    @Test func invalidInputsDoNotCrash() {
        for aspect in [0.0, -1, .nan, .infinity] {
            let m = OverlayMapping(viewSize: phone, imageAspect: aspect, gravity: .aspectFill)
            #expect(m.contentRect == CGRect(origin: .zero, size: phone))
            _ = m.viewPoint(x: 0.5, y: 0.5)
        }
        let zero = OverlayMapping(viewSize: .zero, imageAspect: 1, gravity: .aspectFit)
        #expect(zero.normalizedPoint(for: .zero) == (0, 0))
        #expect(zero.visibleNormalizedRect == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test func viewPointsAndBoneSegments() throws {
        let frame = PoseFrame(
            t: 0,
            joints: [
                .leftShoulder: Keypoint(x: 0.4, y: 0.7, confidence: 0.9),
                .leftElbow: Keypoint(x: 0.45, y: 0.55, confidence: 0.8),
                .leftWrist: Keypoint(x: 0.5, y: 0.4, confidence: 0.1),
            ],
            imageAspect: 1
        )
        let m = OverlayMapping(viewSize: CGSize(width: 100, height: 100), imageAspect: 1, gravity: .stretch)
        #expect(m.viewPoints(for: frame).count == 3)
        let confident = m.viewPoints(for: frame, minimumConfidence: 0.3)
        #expect(confident.keys.sorted { $0.rawValue < $1.rawValue } == [.leftElbow, .leftShoulder])
        expectClose(try #require(confident[.leftShoulder]), CGPoint(x: 40, y: 30))

        let segments = m.boneSegments(for: frame)
        let upperArm = try #require(segments.first { $0.bone.from == .leftShoulder && $0.bone.to == .leftElbow })
        expectClose(upperArm.from, CGPoint(x: 40, y: 30))
        expectClose(upperArm.to, CGPoint(x: 45, y: 45))
        // The forearm has a low-confidence wrist, so it is not drawn.
        #expect(!segments.contains { $0.bone.to == .leftWrist || $0.bone.from == .leftWrist })
        #expect(m.boneSegments(for: frame, minimumConfidence: 0).contains { $0.bone.to == .leftWrist })
    }

    @Test func mirroredPoseFrameDrawsOnTheMirroredSide() {
        // PoseFrame x is already mirrored like the preview, so the overlay needs no flip of its own: a
        // joint at x = 0.2 sits at the left of the picture the user sees.
        let m = OverlayMapping(viewSize: CGSize(width: 300, height: 600), imageAspect: 0.5, gravity: .aspectFill)
        #expect(m.viewPoint(x: 0.2, y: 0.5).x < m.viewPoint(x: 0.8, y: 0.5).x)
    }
}
