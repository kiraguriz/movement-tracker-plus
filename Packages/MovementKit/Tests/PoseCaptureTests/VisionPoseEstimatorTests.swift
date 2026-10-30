import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import MotionCore
import Testing
import Vision
@testable import PoseCapture

private func inverse(_ o: CGImagePropertyOrientation) -> CGImagePropertyOrientation {
    // The two quarter turns undo each other; the mirrors and the half turn are their own inverse.
    switch o {
    case .left: .right
    case .right: .left
    default: o
    }
}

private func makeImage(width: Int, height: Int, draw: (CGContext) -> Void = { _ in }) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.06, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(context)
    return try #require(context.makeImage())
}

/// An upright picture with one bright rectangle, low and to the left (CoreGraphics y is up, like Vision).
private func uprightRectanglePicture() throws -> CGImage {
    try makeImage(width: 400, height: 300) { context in
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(x: 40, y: 30, width: 120, height: 80))
    }
}

private func pixelBuffer(of image: CGImage) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, nil, &buffer)
    let result = try #require(buffer)
    CVPixelBufferLockBaseAddress(result, [])
    defer { CVPixelBufferUnlockBaseAddress(result, []) }
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: CVPixelBufferGetBaseAddress(result), width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(result), space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return result
}

@Suite("Vision pose estimator")
struct VisionPoseEstimatorTests {
    /// The foundation of the coordinate convention in `PoseGeometry`: Vision reports normalized coordinates
    /// of the *oriented* (upright) image. A rectangle detector shows it for all eight orientations without
    /// needing a person in the picture: the raw image is the upright one turned by the inverse of the
    /// orientation, and Vision, told the orientation, must find the rectangle where it is in the upright
    /// picture. (The same property was checked for body pose on a photograph of a person; see the report.)
    @Test("Vision reports the oriented image's coordinates", arguments: allOrientations)
    func visionUsesOrientedCoordinates(_ orientation: CGImagePropertyOrientation) async throws {
        let upright = try uprightRectanglePicture()
        let context = CIContext()
        let turned = CIImage(cgImage: upright).oriented(inverse(orientation))
        let raw = try #require(context.createCGImage(turned, from: turned.extent))

        var request = DetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.minimumSize = 0.1
        let found = try await request.perform(on: raw, orientation: orientation)
        let box = try #require(found.first).boundingBox

        // Expected in the upright picture: x 40...160 of 400, y 30...110 of 300, origin bottom-left.
        #expect(abs(box.origin.x - 0.10) < 0.04, "\(orientation)")
        #expect(abs(box.origin.y - 0.10) < 0.04, "\(orientation)")
        #expect(abs(box.width - 0.30) < 0.04, "\(orientation)")
        #expect(abs(box.height - 80.0 / 300) < 0.04, "\(orientation)")
    }

    @Test func noPersonGivesNil() async throws {
        let estimator = VisionPoseEstimator()
        let image = try makeImage(width: 640, height: 480)
        #expect(try await estimator.estimate(image: image) == nil)
        #expect(try await estimator.estimate(pixelBuffer: pixelBuffer(of: image), time: 1) == nil)
    }

    @Test func measureReturnsAnEmptyFrameWithTimingAndTheOrientedAspect() async throws {
        let estimator = VisionPoseEstimator()
        let image = try makeImage(width: 640, height: 480)
        for (orientation, aspect) in [(CGImagePropertyOrientation.up, 640.0 / 480), (.right, 480.0 / 640), (.leftMirrored, 480.0 / 640)] {
            let estimate = try await estimator.measure(image: image, orientation: orientation, mirrored: true, time: 4.5)
            #expect(!estimate.personFound)
            #expect(estimate.peopleCount == 0)
            #expect(estimate.frame.joints.isEmpty)
            #expect(estimate.frame.t == 4.5)
            #expect(abs(estimate.frame.imageAspect - aspect) < 1e-12)
            #expect(estimate.visionSeconds > 0)
        }
    }

    @Test func pixelBufferPathReportsTheOrientedAspectToo() async throws {
        let estimator = VisionPoseEstimator()
        let buffer = try pixelBuffer(of: makeImage(width: 1280, height: 720))
        let estimate = try await estimator.measure(pixelBuffer: buffer, orientation: .right, mirrored: false, time: 0)
        #expect(abs(estimate.frame.imageAspect - 720.0 / 1280) < 1e-12)
    }

    @Test func blockingBridgeWorksFromAPlainQueue() async throws {
        let estimator = VisionPoseEstimator()
        let buffer = UncheckedSendable(try pixelBuffer(of: makeImage(width: 640, height: 480)))
        let estimate = await withCheckedContinuation { continuation in
            DispatchQueue(label: "test.video").async {
                continuation.resume(returning: estimator.measureBlocking(pixelBuffer: buffer.value, orientation: .up, mirrored: false, time: 7))
            }
        }
        let value = try #require(estimate)
        #expect(!value.personFound)
        #expect(value.frame.t == 7)
    }

    @Test func repeatedCallsAcrossInputTypesKeepWorking() async throws {
        // Vision can fail once right after the input type changes; the estimator retries, so alternating
        // between pixel buffers and images never surfaces an error.
        let estimator = VisionPoseEstimator()
        let image = try makeImage(width: 320, height: 240)
        let buffer = try pixelBuffer(of: image)
        for i in 0..<4 {
            _ = try await estimator.measure(image: image, time: Double(i))
            _ = try await estimator.measure(pixelBuffer: buffer, time: Double(i))
        }
    }
}
