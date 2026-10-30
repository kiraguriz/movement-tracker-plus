import Foundation
import Vision

/// Which Vision failures get a second try, and how every failure is reported.
///
/// Observed on macOS 27.2: the first plain (not IOSurface-backed) BGRA pixel buffer handed to a request after
/// a `CGImage` fails once with `NSOSStatusErrorDomain` -18 ("failed to processImage") and then works. The
/// same kind of first-use failure has been seen as -12905 (`kVTPixelTransferNotSupportedErr`, Vision's own
/// pixel conversion). Those two are retried once. Everything else is a real error (a bad image, a missing
/// model, an unsupported request) and is reported on the first failure: retrying it would only repeat the
/// failure and hide how long it took. Cancellation is never an error to report or to retry.
enum VisionRetryPolicy {
    /// `kVTPixelTransferNotSupportedErr`.
    static let pixelTransferNotSupported = -12905
    /// The status Vision reports for "failed to processImage" on a first-use failure.
    static let processImageFailed = -18

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let vision = error as? VisionError, case .requestCancelled = vision { return true }
        return false
    }

    static func isTransient(_ error: any Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSOSStatusErrorDomain else { return false }
        switch ns.code {
        case pixelTransferNotSupported: return true
        case processImageFailed: return ns.localizedDescription.contains("failed to processImage")
        default: return false
        }
    }

    /// For example `NSOSStatusErrorDomain -18: Error: failed to processImage`.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) \(ns.code): \(ns.localizedDescription)"
    }

    /// Runs `body`; a transient failure is retried once. Cancellation is rethrown as it is, any other
    /// failure becomes `PoseEstimatorError.visionFailed` with the underlying domain and code.
    static func run<T>(_ body: () async throws -> T) async throws -> T {
        var retried = false
        while true {
            do {
                return try await body()
            } catch {
                if isCancellation(error) { throw error }
                if !retried, isTransient(error) {
                    retried = true
                    continue
                }
                throw PoseEstimatorError.visionFailed(describe(error))
            }
        }
    }
}
