import AVFoundation
import MotionCore
import PoseCapture
import SwiftUI
import UIKit

/// The one UIKit view of the Live Set: the camera preview layer with the skeleton drawn over it by two
/// `CAShapeLayer`s. Each frame redraws the paths directly (no SwiftUI diffing) through `OverlayMapping`, so the
/// skeleton sits on the picture however the view is sized or turned.
///
/// Without a camera (Simulator, tests, demo rehearsal) the preview layer is hidden and the skeleton is drawn on
/// a plain background, with the whole picture visible (aspect fit) so a landscape recording is not cropped.
final class CameraIslandView: UIView {
    enum Backdrop {
        case camera
        case plain
    }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // `layerClass` is the preview layer, so this cannot fail.
        layer as! AVCaptureVideoPreviewLayer
    }

    /// Quarter turns between the frames' picture and the preview's (`CameraPipeline.overlayQuarterTurns`).
    var quarterTurns: () -> Int = { 0 }

    private(set) var backdrop = Backdrop.camera
    private let stage = CALayer()
    private let bones = CAShapeLayer()
    private let joints = CAShapeLayer()
    private var lastFrame: PoseFrame?
    private var mapping: OverlayMapping?

    private static let minimumConfidence = 0.3
    private static let jointRadius = 5.0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        backgroundColor = UIColor(white: 0.06, alpha: 1)
        previewLayer.videoGravity = .resizeAspectFill

        stage.backgroundColor = UIColor(white: 0.12, alpha: 1).cgColor
        stage.cornerRadius = 12
        stage.isHidden = true
        layer.addSublayer(stage)

        for shape in [bones, joints] {
            shape.shadowColor = UIColor.black.cgColor
            shape.shadowOpacity = 0.5
            shape.shadowRadius = 2
            shape.shadowOffset = .zero
            layer.addSublayer(shape)
        }
        bones.fillColor = nil
        bones.strokeColor = UIColor.white.withAlphaComponent(0.92).cgColor
        bones.lineWidth = 4
        bones.lineCap = .round
        bones.lineJoin = .round
        joints.fillColor = UIColor.systemGreen.cgColor
        joints.strokeColor = nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setBackdrop(_ backdrop: Backdrop) {
        self.backdrop = backdrop
        stage.isHidden = backdrop == .camera
        mapping = nil
        draw(lastFrame)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bones.frame = bounds
        joints.frame = bounds
        bones.contentsScale = traitCollection.displayScale
        joints.contentsScale = traitCollection.displayScale
        mapping = nil
        draw(lastFrame)
    }

    /// Draws the skeleton of the newest frame. Call on the main thread, at most once per frame.
    func update(_ frame: PoseFrame?) {
        lastFrame = frame
        draw(frame)
    }

    private func draw(_ frame: PoseFrame?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard let frame, bounds.width > 0, bounds.height > 0 else {
            bones.path = nil
            joints.path = nil
            return
        }
        let gravity: OverlayMapping.Gravity = backdrop == .camera ? .aspectFill : .aspectFit
        let turns = backdrop == .camera ? quarterTurns() : 0
        if mapping?.imageAspect != frame.imageAspect || mapping?.viewSize != bounds.size
            || mapping?.quarterTurns != turns || mapping?.gravity != gravity {
            mapping = OverlayMapping(viewSize: bounds.size, imageAspect: frame.imageAspect, gravity: gravity, quarterTurns: turns)
            if let content = mapping?.contentRect { stage.frame = content }
        }
        guard let mapping else { return }

        let bonePath = CGMutablePath()
        for segment in mapping.boneSegments(for: frame, minimumConfidence: Self.minimumConfidence) {
            bonePath.move(to: segment.from)
            bonePath.addLine(to: segment.to)
        }
        let jointPath = CGMutablePath()
        let radius = Self.jointRadius
        for point in mapping.viewPoints(for: frame, minimumConfidence: Self.minimumConfidence).values {
            jointPath.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
        }
        bones.path = bonePath
        joints.path = jointPath
    }
}

/// Wraps `CameraIslandView` once for SwiftUI. The view model gets the UIKit view to feed frames into and to
/// connect the camera preview to; SwiftUI never re-renders it.
struct CameraIsland: UIViewRepresentable {
    let model: LiveSetModel

    func makeUIView(context: Context) -> CameraIslandView {
        let view = CameraIslandView()
        model.attach(island: view)
        return view
    }

    func updateUIView(_ view: CameraIslandView, context: Context) {}

    static func dismantleUIView(_ view: CameraIslandView, coordinator: ()) {
        view.update(nil)
    }
}
