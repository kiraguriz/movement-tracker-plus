import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MotionCore

/// Renders a `PoseFrame` as a PNG skeleton picture for the coach (set review sends the best and worst rep
/// bottoms to Muse): plain dark background, bones and joints, a ground line, and, depending on the
/// exercise spec, horizontal height guides (squat: hip and knee, so depth is visible) and a joint-angle
/// arc with its value (push-up elbow).
///
/// Deterministic: the same frame, spec and options give the same bytes on the same OS version. Pure
/// CoreGraphics, CoreText and ImageIO, so it runs on macOS and iOS and off the main thread.
public struct SkeletonRenderer: Sendable {
    public struct Options: Equatable, Sendable {
        /// Length of the longer image side in pixels (the picture keeps the frame's aspect ratio).
        public var maxDimension: Int = 768
        /// Joints below this confidence are not drawn.
        public var minimumConfidence: Double = 0.3
        /// The body side the spec follows; nil picks the side with the higher confidence.
        public var side: BodySide?
        /// Draw the spec's guides and angle arc.
        public var showGuides = true
        public var showGround = true

        public init(
            maxDimension: Int = 768, minimumConfidence: Double = 0.3, side: BodySide? = nil,
            showGuides: Bool = true, showGround: Bool = true
        ) {
            self.maxDimension = maxDimension
            self.minimumConfidence = minimumConfidence
            self.side = side
            self.showGuides = showGuides
            self.showGround = showGround
        }
    }

    public enum RenderError: Error, Equatable, Sendable {
        case contextCreationFailed
        case encodingFailed
    }

    public let spec: ExerciseSpec?
    public let options: Options

    public init(spec: ExerciseSpec? = nil, options: Options = Options()) {
        self.spec = spec
        self.options = options
    }

    /// The pixel size of the picture for a given image aspect ratio.
    public func imageSize(forAspect aspect: Double) -> (width: Int, height: Int) {
        let a = aspect.isFinite ? min(max(aspect, 0.2), 5) : 1
        let long = max(64, options.maxDimension)
        if a >= 1 { return (long, max(1, Int((Double(long) / a).rounded()))) }
        return (max(1, Int((Double(long) * a).rounded())), long)
    }

    /// PNG data of the picture.
    public func pngData(for frame: PoseFrame, repLabel: String? = nil) throws -> Data {
        let image = try image(for: frame, repLabel: repLabel)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw RenderError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.encodingFailed }
        return data as Data
    }

    /// The picture as a bitmap (top row first, like any `CGImage`).
    public func image(for frame: PoseFrame, repLabel: String? = nil) throws -> CGImage {
        let (width, height) = imageSize(forAspect: frame.imageAspect)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw RenderError.contextCreationFailed }
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)

        var drawing = Drawing(context: context, width: Double(width), height: Double(height), frame: frame, renderer: self)
        drawing.draw(repLabel: repLabel)
        guard let image = context.makeImage() else { throw RenderError.contextCreationFailed }
        return image
    }

    // MARK: - Drawing

    private enum Palette {
        static let background = CGColor(srgbRed: 0.071, green: 0.086, blue: 0.110, alpha: 1)
        static let ground = CGColor(srgbRed: 0.42, green: 0.45, blue: 0.50, alpha: 1)
        static let left = CGColor(srgbRed: 0.30, green: 0.64, blue: 1.00, alpha: 1)
        static let right = CGColor(srgbRed: 1.00, green: 0.62, blue: 0.26, alpha: 1)
        static let midline = CGColor(srgbRed: 0.90, green: 0.91, blue: 0.94, alpha: 1)
        static let guideUpper = CGColor(srgbRed: 1.00, green: 0.36, blue: 0.54, alpha: 1)
        static let guideLower = CGColor(srgbRed: 0.24, green: 0.86, blue: 0.59, alpha: 1)
        static let arc = CGColor(srgbRed: 1.00, green: 0.82, blue: 0.40, alpha: 1)
        static let text = CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1)

        static func color(for side: BodySide?) -> CGColor {
            switch side {
            case .left: left
            case .right: right
            case nil: midline
            }
        }
    }

    private struct Drawing {
        let context: CGContext
        let width: Double
        let height: Double
        let frame: PoseFrame
        let renderer: SkeletonRenderer

        var options: Options { renderer.options }
        var scale: Double { min(width, height) }
        var side: BodySide { renderer.followedSide(in: frame) }

        func point(_ k: Keypoint) -> CGPoint { CGPoint(x: k.x * width, y: k.y * height) }

        func confident(_ joint: Joint) -> Keypoint? {
            guard let k = frame.joints[joint], k.confidence >= options.minimumConfidence else { return nil }
            return k
        }

        mutating func draw(repLabel: String?) {
            context.setFillColor(Palette.background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            if options.showGround { drawGround() }
            if options.showGuides, let spec = renderer.spec { drawGuides(for: spec) }
            drawBones()
            drawJoints()
            if options.showGuides, let spec = renderer.spec { drawAngleArc(for: spec) }
            if let repLabel, !repLabel.isEmpty {
                drawText(repLabel, at: CGPoint(x: scale * 0.03, y: height - scale * 0.03), size: scale * 0.04,
                         color: Palette.text, anchor: .topLeading)
            }
        }

        // The floor sits at the lowest confident ankle.
        func drawGround() {
            let ankles = [Joint.leftAnkle, .rightAnkle].compactMap { confident($0) }
            guard let lowest = ankles.map({ $0.y }).min() else { return }
            context.setStrokeColor(Palette.ground)
            context.setLineWidth(max(2, scale * 0.004))
            context.setLineDash(phase: 0, lengths: [])
            let y = lowest * height
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
            context.strokePath()
        }

        func drawGuides(for spec: ExerciseSpec) {
            guard case let .relativeHeight(of, to, _) = spec.signal else { return }
            let pairs: [(JointRole, CGColor)] = [(of, Palette.guideUpper), (to, Palette.guideLower)]
            let lines = pairs.compactMap { role, color in
                confident(role.joint(on: side)).map { (role: role, color: color, y: $0.y * height) }
            }
            // Higher in the picture means larger y; a tie goes to the first line (the hip).
            let higher = lines.indices.max { (lines[$0].y, -$0) < (lines[$1].y, -$1) }
            for (index, line) in lines.enumerated() {
                context.setStrokeColor(line.color)
                context.setLineWidth(max(2, scale * 0.004))
                context.setLineDash(phase: 0, lengths: [scale * 0.02, scale * 0.012])
                context.move(to: CGPoint(x: 0, y: line.y))
                context.addLine(to: CGPoint(x: width, y: line.y))
                context.strokePath()
                context.setLineDash(phase: 0, lengths: [])
                // The higher line carries its name above it and the lower one below it, so the two names
                // never collide when hip and knee are level, which is exactly the parallel squat.
                let isHigher = index == higher
                let gap = scale * 0.008
                drawText(
                    line.role.rawValue, at: CGPoint(x: width - scale * 0.02, y: line.y + (isHigher ? gap : -gap)),
                    size: scale * 0.032, color: line.color, anchor: isHigher ? .bottomTrailing : .topTrailing
                )
            }
        }

        func drawBones() {
            let followed = side
            let thin = max(3, scale * 0.0065)
            for emphasized in [false, true] {
                for bone in Skeleton.bones {
                    let onFollowed = bone.side == followed
                    guard onFollowed == emphasized,
                          let a = confident(bone.from), let b = confident(bone.to) else { continue }
                    context.setStrokeColor(Palette.color(for: bone.side))
                    context.setLineWidth(emphasized ? thin * 1.35 : thin)
                    context.setLineCap(.round)
                    context.move(to: point(a))
                    context.addLine(to: point(b))
                    context.strokePath()
                }
            }
        }

        func drawJoints() {
            let radius = max(4, scale * 0.0115)
            for joint in Joint.allCases {
                guard let k = confident(joint) else { continue }
                let p = point(k)
                let emphasized = joint.side == side || joint.side == nil
                let r = emphasized ? radius * 1.15 : radius
                context.setFillColor(Palette.color(for: joint.side))
                context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }

        // The included angle at the middle joint of a `jointAngle` signal, measured the way the engine
        // measures it (isotropic units: here, pixels).
        func drawAngleArc(for spec: ExerciseSpec) {
            guard case let .jointAngle(a, b, c) = spec.signal,
                  let ka = confident(a.joint(on: side)), let kb = confident(b.joint(on: side)),
                  let kc = confident(c.joint(on: side)) else { return }
            let pa = point(ka), pb = point(kb), pc = point(kc)
            let u = CGVector(dx: pa.x - pb.x, dy: pa.y - pb.y)
            let v = CGVector(dx: pc.x - pb.x, dy: pc.y - pb.y)
            let lu = hypot(u.dx, u.dy), lv = hypot(v.dx, v.dy)
            guard lu > 1e-6, lv > 1e-6 else { return }
            let cosine = max(-1, min(1, (u.dx * v.dx + u.dy * v.dy) / (lu * lv)))
            let degrees = acos(cosine) * 180 / .pi

            let start = atan2(u.dy, u.dx)
            let end = atan2(v.dy, v.dx)
            var delta = end - start
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            let radius = max(18, min(lu, lv) * 0.45, scale * 0.06)

            context.setStrokeColor(Palette.arc)
            context.setLineWidth(max(3, scale * 0.006))
            context.setLineCap(.round)
            context.addArc(center: pb, radius: radius, startAngle: start, endAngle: end, clockwise: delta < 0)
            context.strokePath()

            let mid = start + delta / 2
            let labelRadius = radius + scale * 0.035
            drawText("\(Int(degrees.rounded()))°",
                     at: CGPoint(x: pb.x + cos(mid) * labelRadius, y: pb.y + sin(mid) * labelRadius),
                     size: scale * 0.04, color: Palette.arc, anchor: .center)
        }

        enum Anchor { case center, topLeading, bottomTrailing, topTrailing }

        func drawText(_ string: String, at point: CGPoint, size: Double, color: CGColor, anchor: Anchor) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(10, size), nil)
            let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
            guard let attributed = CFAttributedStringCreate(nil, string as CFString, attributes as CFDictionary) else { return }
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, [])
            var origin = point
            switch anchor {
            case .center:
                origin = CGPoint(x: point.x - bounds.midX, y: point.y - bounds.midY)
            case .topLeading:
                origin = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.maxY)
            case .bottomTrailing:
                origin = CGPoint(x: point.x - bounds.maxX, y: point.y - bounds.minY)
            case .topTrailing:
                origin = CGPoint(x: point.x - bounds.maxX, y: point.y - bounds.maxY)
            }
            context.textPosition = origin
            CTLineDraw(line, context)
        }
    }

    /// The side drawn emphasized: the option if set, else the side whose spec joints (or all joints
    /// without a spec) carry the higher total confidence. Ties go to the left.
    func followedSide(in frame: PoseFrame) -> BodySide {
        if let side = options.side { return side }
        func score(_ side: BodySide) -> Double {
            if let spec {
                return spec.requiredJoints.reduce(0) { $0 + (frame.joints[$1.joint(on: side)]?.confidence ?? 0) }
            }
            return Joint.allCases.filter { $0.side == side }.reduce(0) { $0 + (frame.joints[$1]?.confidence ?? 0) }
        }
        return score(.right) > score(.left) ? .right : .left
    }
}
