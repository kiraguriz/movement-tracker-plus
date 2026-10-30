import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Writes a small H.264 movie of flat grey frames: no person in it, but real frame timing, size and
/// preferred transform, which is what the video source has to get right.
enum TestMovie {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    /// A transform that turns a landscape stored frame upright for a portrait capture (`.right`).
    static func portraitTransform(storedHeight: Int) -> CGAffineTransform {
        CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(storedHeight), ty: 0)
    }

    private static func flatBuffer(width: Int, height: Int, grey: Int) throws -> sending CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &created)
        guard let buffer = created else { throw Failure(description: "no pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, Int32(grey), CVPixelBufferGetBytesPerRow(buffer) * height)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func write(
        to url: URL, width: Int = 320, height: Int = 240, frameCount: Int = 30, fps: Int32 = 30,
        transform: CGAffineTransform = .identity
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.transform = transform
        let attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: width, height: height)
        )
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: attributes)
        try writer.start()
        writer.startSession(atSourceTime: CMTime(value: 0, timescale: fps))

        for index in 0..<frameCount {
            let buffer = try flatBuffer(width: width, height: height, grey: 90 + (index * 3) % 60)
            let time = CMTime(value: CMTimeValue(index), timescale: fps)
            try await receiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: buffer), with: time)
        }
        receiver.finish()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure(description: "finishWriting: \(String(describing: writer.error))") }
    }
}

/// A fresh empty directory for one test, removed when the value goes away.
final class TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("PoseCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}
