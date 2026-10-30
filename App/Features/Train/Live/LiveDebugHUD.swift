#if DEBUG
import PoseCapture
import SwiftUI

/// Camera and engine numbers over the Live Set, in Debug builds only. This is the on-device gate for Vision
/// latency and for the PoseCapture checklist: frame rate, Vision p50/p95 latency, dropped frames, the capture and
/// preview rotation and the overlay's quarter turns (they must agree with what is on screen), whether Center
/// Stage or stabilization is cropping the picture (neither may be), and the capture format.
///
/// Shown from the launch argument `-MTDebugHUD` or by a long press on the rep counter. It polls four times a
/// second and takes no input.
struct LiveDebugHUD: View {
    let model: LiveSetModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(alignment: .leading, spacing: 1) {
                ForEach(lines, id: \.self) { line in
                    Text(verbatim: line)
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(8)
            .background(.black.opacity(0.65), in: .rect(cornerRadius: 10))
            .fixedSize(horizontal: false, vertical: true)
            .dynamicTypeSize(...DynamicTypeSize.large)
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier(AccessibilityID.liveHUD)
    }

    private var lines: [String] {
        let rate = model.deliveryRate
        guard let stats = model.cameraStats else {
            return [
                "replay  frames \(rate.frames)",
                String(format: "delivered %.1f fps", rate.fps),
            ]
        }
        let person = stats.framesProcessed > 0 ? 100 * stats.framesWithPerson / stats.framesProcessed : 0
        let latency = stats.visionLatency
        return [
            String(format: "%.1f fps  target %.0f  dropped %d", stats.deliveredFPS, stats.targetFrameRate, stats.droppedFrames),
            String(format: "vision p50 %.1f  p95 %.1f  max %.1f ms", latency.p50 * 1000, latency.p95 * 1000, latency.max * 1000),
            "frames \(stats.framesProcessed)  person \(person)%  failed \(stats.visionFailures)",
            "format \(stats.format)",
            "\(stats.cameraName)  mirrored \(stats.isMirrored ? "yes" : "no")",
            String(
                format: "rotation capture %.0f  preview %@  overlay turns %d",
                stats.captureRotationAngle,
                stats.previewRotationAngle.map { String(format: "%.0f", $0) } ?? "-",
                stats.overlayQuarterTurns
            ),
            "orientation \(stats.orientation.rawValue)  pressure \(String(describing: stats.pressure))",
            "center stage \(stats.centerStageActive ? "ON" : "off")  stabilization \(stats.stabilizationActive ? "ON" : "off")",
        ]
    }
}
#endif
