import CoreGraphics
import Foundation
import ImageIO
import MotionCore
import Testing
@testable import PoseCapture

/// RGBA pixels of a decoded image, row 0 at the top.
private struct Pixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let drawn = data.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        #expect(drawn)
        width = w
        height = h
        bytes = data
    }

    init(png: Data) throws {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        try self.init(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    /// The pixel under a pose point (origin bottom-left, y up).
    func at(x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        let column = min(width - 1, max(0, Int(x * Double(width))))
        let row = min(height - 1, max(0, Int((1 - y) * Double(height))))
        let i = (row * width + column) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}

private let background = (r: 18, g: 22, b: 28)    // 0.071, 0.086, 0.110 of 255

private func isBackground(_ p: (r: Int, g: Int, b: Int)) -> Bool {
    abs(p.r - background.r) <= 2 && abs(p.g - background.g) <= 2 && abs(p.b - background.b) <= 2
}

private func squatFrame(aspect: Double = 9.0 / 16, confidence: Double = 0.9) -> PoseFrame {
    func k(_ x: Double, _ y: Double) -> Keypoint { Keypoint(x: x, y: y, confidence: confidence) }
    return PoseFrame(
        t: 1,
        joints: [
            .nose: k(0.55, 0.88), .neck: k(0.52, 0.80), .leftShoulder: k(0.50, 0.78), .rightShoulder: k(0.54, 0.78),
            .leftElbow: k(0.55, 0.66), .leftWrist: k(0.60, 0.58), .root: k(0.42, 0.50),
            .leftHip: k(0.40, 0.48), .rightHip: k(0.44, 0.48), .leftKnee: k(0.55, 0.40), .rightKnee: k(0.58, 0.40),
            .leftAnkle: k(0.46, 0.12), .rightAnkle: k(0.49, 0.12),
        ],
        imageAspect: aspect
    )
}

@Suite("Skeleton renderer")
struct SkeletonRendererTests {
    private let squat = try! ExerciseSpec.bundled(.squatBodyweight)
    private let pushUp = try! ExerciseSpec.bundled(.pushUp)

    @Test func sameInputGivesTheSameBytes() throws {
        let frame = squatFrame()
        let a = try SkeletonRenderer(spec: squat).pngData(for: frame, repLabel: "Rep 3")
        let b = try SkeletonRenderer(spec: squat).pngData(for: frame, repLabel: "Rep 3")
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test func outputIsAPNGOfTheExpectedSize() throws {
        let renderer = SkeletonRenderer(spec: squat)
        let data = try renderer.pngData(for: squatFrame())
        #expect(Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 432 && image.height == 768)

        let wide = try SkeletonRenderer().image(for: squatFrame(aspect: 16.0 / 9))
        #expect(wide.width == 768 && wide.height == 432)
    }

    @Test func imageSizeKeepsAspectAndLongSide() {
        let renderer = SkeletonRenderer(options: .init(maxDimension: 512))
        #expect(renderer.imageSize(forAspect: 1) == (512, 512))
        #expect(renderer.imageSize(forAspect: 0.5) == (256, 512))
        #expect(renderer.imageSize(forAspect: 2) == (512, 256))
        // Absurd or invalid aspects are bounded.
        #expect(renderer.imageSize(forAspect: 0.0001).width >= 1)
        #expect(renderer.imageSize(forAspect: .nan) == (512, 512))
        #expect(renderer.imageSize(forAspect: .infinity) == (512, 512))
    }

    @Test func backgroundIsPlain() throws {
        let pixels = try Pixels(png: SkeletonRenderer(spec: squat).pngData(for: squatFrame()))
        for (x, y) in [(0.02, 0.02), (0.98, 0.98), (0.02, 0.98), (0.98, 0.02)] {
            #expect(isBackground(pixels.at(x: x, y: y)), "corner \(x),\(y)")
        }
    }

    @Test func aBoneIsDrawnWhereTheKeypointsSayAndNowhereElse() throws {
        // y is up in the frame, so a bone high in the frame must be drawn high in the picture, and x is not
        // flipped (the frame is already mirrored like the preview).
        let frame = PoseFrame(
            t: 0,
            joints: [
                .leftShoulder: Keypoint(x: 0.3, y: 0.8, confidence: 1),
                .leftElbow: Keypoint(x: 0.3, y: 0.6, confidence: 1),
            ],
            imageAspect: 0.5
        )
        let renderer = SkeletonRenderer(options: .init(showGuides: false, showGround: false))
        let pixels = try Pixels(png: renderer.pngData(for: frame))
        #expect(!isBackground(pixels.at(x: 0.3, y: 0.7)))        // middle of the bone
        #expect(!isBackground(pixels.at(x: 0.3, y: 0.8)))        // the shoulder joint
        #expect(isBackground(pixels.at(x: 0.7, y: 0.7)))         // mirrored x
        #expect(isBackground(pixels.at(x: 0.3, y: 0.3)))         // flipped y
        #expect(isBackground(pixels.at(x: 0.3, y: 0.9)))         // beyond the end
    }

    @Test func leftIsBlueAndRightIsOrange() throws {
        func colour(_ a: Joint, _ b: Joint) throws -> (r: Int, g: Int, b: Int) {
            let frame = PoseFrame(
                t: 0, joints: [a: Keypoint(x: 0.3, y: 0.8, confidence: 1), b: Keypoint(x: 0.3, y: 0.6, confidence: 1)],
                imageAspect: 0.5
            )
            let renderer = SkeletonRenderer(options: .init(showGuides: false, showGround: false))
            return try Pixels(png: renderer.pngData(for: frame)).at(x: 0.3, y: 0.7)
        }
        let left = try colour(.leftShoulder, .leftElbow)
        let right = try colour(.rightShoulder, .rightElbow)
        #expect(left.b > left.r + 60)
        #expect(right.r > right.b + 60)
    }

    @Test func lowConfidenceJointsAreNotDrawn() throws {
        let faint = squatFrame(confidence: 0.1)
        let empty = PoseFrame(t: 1, joints: [:], imageAspect: faint.imageAspect)
        let renderer = SkeletonRenderer(spec: squat)
        #expect(try renderer.pngData(for: faint) == renderer.pngData(for: empty))
        #expect(try renderer.pngData(for: squatFrame()) != renderer.pngData(for: empty))
    }

    @Test func emptyFrameStillRenders() throws {
        let data = try SkeletonRenderer().pngData(for: PoseFrame(t: 0, joints: [:], imageAspect: 1))
        let pixels = try Pixels(png: data)
        #expect(isBackground(pixels.at(x: 0.5, y: 0.5)))
    }

    @Test func groundLineSitsAtTheLowestAnkle() throws {
        let frame = squatFrame()
        let withGround = try Pixels(png: SkeletonRenderer(options: .init(showGuides: false)).pngData(for: frame))
        let without = try Pixels(png: SkeletonRenderer(options: .init(showGuides: false, showGround: false)).pngData(for: frame))
        // Far left of the picture at ankle height: the ground line crosses it, nothing else does.
        #expect(!isBackground(withGround.at(x: 0.05, y: 0.12)))
        #expect(isBackground(without.at(x: 0.05, y: 0.12)))
        #expect(isBackground(withGround.at(x: 0.05, y: 0.30)))
    }

    @Test func squatGuidesMarkHipAndKneeHeight() throws {
        let frame = squatFrame()
        let spec = squat
        guard case let .relativeHeight(of, to, _) = spec.signal else {
            Issue.record("the squat spec is expected to measure relative height")
            return
        }
        let side = SkeletonRenderer(spec: spec).followedSide(in: frame)
        let hipY = try #require(frame.joints[of.joint(on: side)]).y
        let kneeY = try #require(frame.joints[to.joint(on: side)]).y

        let withGuides = try Pixels(png: SkeletonRenderer(spec: spec, options: .init(showGround: false)).pngData(for: frame))
        let without = try Pixels(png: SkeletonRenderer(spec: spec, options: .init(showGuides: false, showGround: false)).pngData(for: frame))
        // The guide is dashed, so look along the line at the far-left strip for any guide pixel.
        func hasGuide(_ pixels: Pixels, y: Double) -> Bool {
            stride(from: 0.0, to: 0.12, by: 0.002).contains { !isBackground(pixels.at(x: $0, y: y)) }
        }
        #expect(hasGuide(withGuides, y: hipY))
        #expect(hasGuide(withGuides, y: kneeY))
        #expect(!hasGuide(without, y: hipY))
        #expect(!hasGuide(without, y: kneeY))
    }

    @Test func specsDecideWhichAnnotationsAppear() throws {
        let frame = squatFrame()
        let plain = try SkeletonRenderer().pngData(for: frame)
        #expect(try SkeletonRenderer(spec: squat).pngData(for: frame) != plain)              // height guides
        #expect(try SkeletonRenderer(spec: squat, options: .init(showGuides: false)).pngData(for: frame) == plain)
        // The push-up spec measures an elbow angle: an arc appears when shoulder, elbow and wrist are known.
        #expect(try SkeletonRenderer(spec: pushUp).pngData(for: frame) != plain)
        let noArm = PoseFrame(t: 0, joints: frame.joints.filter { $0.key != .leftWrist && $0.key != .rightWrist }, imageAspect: frame.imageAspect)
        let noArmPlain = try SkeletonRenderer().pngData(for: noArm)
        #expect(try SkeletonRenderer(spec: pushUp).pngData(for: noArm) == noArmPlain)
    }

    @Test func repLabelChangesTheTopLeftCorner() throws {
        let renderer = SkeletonRenderer(options: .init(showGuides: false))
        let frame = PoseFrame(t: 0, joints: [:], imageAspect: 0.5625)
        let plain = try Pixels(png: renderer.pngData(for: frame))
        let labelled = try Pixels(png: renderer.pngData(for: frame, repLabel: "Rep 7 · bottom"))
        func inked(_ pixels: Pixels) -> Bool {
            stride(from: 0.02, to: 0.45, by: 0.004).contains { x in
                stride(from: 0.93, to: 0.99, by: 0.004).contains { y in !isBackground(pixels.at(x: x, y: y)) }
            }
        }
        #expect(!inked(plain))
        #expect(inked(labelled))
        #expect(try renderer.pngData(for: frame, repLabel: "") == renderer.pngData(for: frame))
    }

    @Test func theFollowedSideIsTheMoreConfidentOne() {
        var frame = squatFrame()
        for joint in [Joint.rightShoulder, .rightHip, .rightKnee, .rightAnkle] {
            frame.joints[joint]?.confidence = 0.35
        }
        #expect(SkeletonRenderer(spec: squat).followedSide(in: frame) == .left)
        #expect(SkeletonRenderer(spec: squat, options: .init(side: .right)).followedSide(in: frame) == .right)
        for joint in [Joint.leftShoulder, .leftHip, .leftKnee, .leftAnkle] {
            frame.joints[joint]?.confidence = 0.31
        }
        #expect(SkeletonRenderer(spec: squat).followedSide(in: frame) == .right)
    }
}
