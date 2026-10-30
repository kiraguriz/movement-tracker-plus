import Foundation
import ImageIO
import Testing
@testable import PoseCapture

@Suite("Camera support")
struct CameraSupportTests {
    private func format(
        _ w: Int, _ h: Int, fps: [ClosedRange<Double>] = [1...30], binned: Bool = false, centerStage: Bool = false,
        biPlanar: Bool = true
    ) -> CaptureFormatCandidate {
        CaptureFormatCandidate(
            width: w, height: h, frameRateRanges: fps, isBinned: binned, supportsCenterStage: centerStage, isBiPlanar420: biPlanar
        )
    }

    @Test func prefersBinnedNearTargetHeight() {
        let candidates = [
            format(1920, 1080), format(1280, 720), format(1280, 720, binned: true), format(640, 480), format(3840, 2160),
        ]
        #expect(CaptureFormatChoice.best(of: candidates) == 2)
    }

    @Test func ignoresFormatsThatCannotDeliverTheFrameRate() {
        let candidates = [format(1280, 720, fps: [1...15], binned: true), format(1920, 1080, fps: [1...30])]
        #expect(CaptureFormatChoice.best(of: candidates, frameRate: 30) == 1)
        #expect(CaptureFormatChoice.best(of: candidates, frameRate: 15) == 0)
    }

    @Test func ignoresPortraitStoredBiPlanarAndOutOfRangeFormats() {
        let candidates = [
            format(720, 1280), format(1280, 720, biPlanar: false), format(320, 240), format(4032, 3024), format(7680, 4320),
        ]
        #expect(CaptureFormatChoice.best(of: candidates) == nil)
        #expect(CaptureFormatChoice.best(of: []) == nil)
    }

    @Test func avoidsCenterStageCroppingWhenOtherwiseEqual() {
        let candidates = [format(1280, 720, centerStage: true), format(1280, 720, centerStage: false)]
        #expect(CaptureFormatChoice.best(of: candidates) == 1)
    }

    @Test func prefersSixteenByNine() {
        let candidates = [format(1280, 960), format(1280, 720)]
        #expect(CaptureFormatChoice.best(of: candidates) == 1)
    }

    @Test func frameRateIsClampedIntoARange() {
        #expect(CaptureFormatChoice.clamp(frameRate: 30, to: [1...30]) == 30)
        #expect(CaptureFormatChoice.clamp(frameRate: 60, to: [1...30]) == 30)
        #expect(CaptureFormatChoice.clamp(frameRate: 5, to: [10...30]) == 10)
        #expect(CaptureFormatChoice.clamp(frameRate: 24, to: [1...15, 25...60]) == 25)
        #expect(CaptureFormatChoice.clamp(frameRate: 24, to: []) == 24)
    }

    @Test func pressureLowersTheFrameRateOnlyWhenHot() {
        #expect(CapturePressure.nominal.frameRate(nominal: 30) == 30)
        #expect(CapturePressure.fair.frameRate(nominal: 30) == 30)
        #expect(CapturePressure.serious.frameRate(nominal: 30) == 20)
        #expect(CapturePressure.critical.frameRate(nominal: 30) == 15)
        #expect(CapturePressure.serious.frameRate(nominal: 15) == 15)
        #expect(CapturePressure.fair < CapturePressure.serious)
    }

    @Test func frameRateMeterAveragesOverItsWindow() {
        var meter = FrameRateMeter(window: 1)
        #expect(meter.fps == 0)
        for i in 0..<61 { meter.record(Double(i) / 30) }
        #expect(abs(meter.fps - 30) < 0.5)
        // The rate falls when frames get sparse.
        for i in 0..<10 { meter.record(4 + Double(i) / 10) }
        #expect(abs(meter.fps - 10) < 0.5)
    }

    @Test func frameRateMeterSurvivesAClockRestart() {
        var meter = FrameRateMeter(window: 1)
        for i in 0..<30 { meter.record(500 + Double(i) / 30) }
        meter.record(1)
        meter.record(1.05)
        #expect(abs(meter.fps - 20) < 0.5)
        meter.record(.nan)
        #expect(abs(meter.fps - 20) < 0.5)
    }

    @Test func emptyStatsAreZero() {
        let stats = CameraStats.empty
        #expect(stats.deliveredFPS == 0 && stats.framesProcessed == 0 && stats.droppedFrames == 0)
        #expect(stats.pressure == .nominal)
        #expect(stats.visionLatency == .empty)
    }
}
