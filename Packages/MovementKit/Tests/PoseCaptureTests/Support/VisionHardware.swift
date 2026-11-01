import CoreGraphics
import Foundation
import Testing
@testable import PoseCapture

/// Probe the actual revision-2 request once. A virtual Metal device does not guarantee that Vision
/// can use its main compute stage. Only the known unavailable-device error disables integration cases;
/// every other error fails the condition so a real regression cannot silently turn into a skip.
enum VisionHardware {
    private enum ProbeError: Error { case imageCreation }

    private static let availability = Task<Bool, any Error> {
        guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = context.makeImage() else { throw ProbeError.imageCreation }
        do {
            _ = try await VisionPoseEstimator().measure(image: image)
            return true
        } catch let PoseEstimatorError.visionFailed(reason) where reason.contains("No available compute device") {
            return false
        }
    }

    static var bodyPose: ConditionTrait {
        .enabled("Requires an available Vision body-pose main-stage compute device") {
            try await availability.value
        }
    }
}
