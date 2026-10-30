import Foundation
import Synchronization
import Testing
import Vision
@testable import PoseCapture

private func osStatus(_ code: Int, _ message: String) -> NSError {
    NSError(domain: NSOSStatusErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
}

private let transientPixelTransfer = osStatus(-12905, "The operation couldn't be completed.")
private let transientProcessImage = osStatus(-18, "Error: failed to processImage")

/// Fails with the given errors in order, then succeeds, counting the calls.
private final class Script: Sendable {
    private let calls = Mutex(0)
    let errors: [any Error]

    init(_ errors: [any Error]) { self.errors = errors }

    var callCount: Int { calls.withLock { $0 } }

    func attempt() async throws -> Int {
        let n = calls.withLock { value -> Int in
            value += 1
            return value
        }
        if n <= errors.count { throw errors[n - 1] }
        return n
    }
}

@Suite("Vision retry policy")
struct VisionRetryPolicyTests {
    @Test("a first-use failure is retried once and then succeeds", arguments: [transientPixelTransfer, transientProcessImage])
    func transientFailureIsRetriedOnce(_ error: NSError) async throws {
        let script = Script([error])
        let value = try await VisionRetryPolicy.run { try await script.attempt() }
        #expect(value == 2)
        #expect(script.callCount == 2)
    }

    @Test("a failure that repeats is not retried again and says what it was", arguments: [transientPixelTransfer, transientProcessImage])
    func aSecondFailureIsReported(_ error: NSError) async {
        let script = Script([error, error, error])
        do {
            _ = try await VisionRetryPolicy.run { try await script.attempt() }
            Issue.record("the failure was swallowed")
        } catch let PoseEstimatorError.visionFailed(message) {
            #expect(message.contains(NSOSStatusErrorDomain))
            #expect(message.contains("\(error.code)"))
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(script.callCount == 2)                      // one try and one retry, never a third
    }

    @Test("other failures are reported at once and never retried", arguments: [
        osStatus(-18, "Error: something else"),                   // -18 is only transient for processImage
        osStatus(-50, "paramErr"),
        osStatus(-12905, "x").withDomain(NSCocoaErrorDomain),     // the code alone means nothing
        VisionError.invalidImage("bad image") as NSError,
        VisionError.operationFailed("the model failed") as NSError,
        CocoaError(.fileReadNoSuchFile) as NSError,
    ])
    func realErrorsAreNotRetried(_ error: NSError) async {
        let script = Script([error, error])
        do {
            _ = try await VisionRetryPolicy.run { try await script.attempt() }
            Issue.record("the failure was swallowed")
        } catch PoseEstimatorError.visionFailed {
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(script.callCount == 1)
    }

    @Test("cancellation is rethrown as it is, never retried and never wrapped", arguments: [
        CancellationError() as any Error,
        VisionError.requestCancelled("cancelled") as any Error,
    ])
    func cancellationPassesThrough(_ error: any Error) async {
        let script = Script([error, error])
        do {
            _ = try await VisionRetryPolicy.run { try await script.attempt() }
            Issue.record("the cancellation was swallowed")
        } catch is PoseEstimatorError {
            Issue.record("the cancellation was reported as a Vision failure")
        } catch {
            #expect(VisionRetryPolicy.isCancellation(error))
        }
        #expect(script.callCount == 1)
    }

    @Test func aCancellationAfterATransientFailureIsStillACancellation() async {
        let script = Script([transientProcessImage, CancellationError()])
        do {
            _ = try await VisionRetryPolicy.run { try await script.attempt() }
            Issue.record("the cancellation was swallowed")
        } catch is CancellationError {
        } catch {
            Issue.record("unexpected \(error)")
        }
        #expect(script.callCount == 2)
    }

    @Test func successNeedsNoRetry() async throws {
        let script = Script([])
        #expect(try await VisionRetryPolicy.run { try await script.attempt() } == 1)
        #expect(script.callCount == 1)
    }

    @Test func descriptionNamesDomainCodeAndText() {
        let text = VisionRetryPolicy.describe(transientProcessImage)
        #expect(text == "\(NSOSStatusErrorDomain) -18: Error: failed to processImage")
    }
}

private extension NSError {
    func withDomain(_ domain: String) -> NSError {
        NSError(domain: domain, code: code, userInfo: userInfo)
    }
}
