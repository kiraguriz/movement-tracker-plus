import Foundation

/// A point in isotropic image units: x is multiplied by the image aspect so one unit is the same
/// distance horizontally and vertically (the unit is the frame height). y still points up.
public struct Point2: Equatable, Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static func - (a: Point2, b: Point2) -> Point2 { Point2(x: a.x - b.x, y: a.y - b.y) }
    public static func + (a: Point2, b: Point2) -> Point2 { Point2(x: a.x + b.x, y: a.y + b.y) }
    public static func * (a: Point2, k: Double) -> Point2 { Point2(x: a.x * k, y: a.y * k) }

    public var length: Double { (x * x + y * y).squareRoot() }
}

/// Plane geometry on isotropic points. All angles are in degrees.
public enum Geometry {
    /// Converts a normalized keypoint into isotropic units (x scaled by the image aspect).
    public static func isotropic(_ keypoint: Keypoint, imageAspect: Double) -> Point2 {
        Point2(x: keypoint.x * imageAspect, y: keypoint.y)
    }

    public static func distance(_ a: Point2, _ b: Point2) -> Double {
        (a - b).length
    }

    /// Included angle at `vertex` between the rays to `a` and `c`, in 0...180. Nil when either ray has
    /// no length, because the angle is then undefined.
    public static func includedAngle(at vertex: Point2, from a: Point2, to c: Point2) -> Double? {
        let u = a - vertex
        let v = c - vertex
        let lu = u.length
        let lv = v.length
        guard lu > 1e-9, lv > 1e-9 else { return nil }
        let cosine = (u.x * v.x + u.y * v.y) / (lu * lv)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }

    /// Angle between the vector `from → to` and the unit vector `up`, in 0...180. Nil for a zero-length
    /// vector. With `up = (0, 1)` this is `angleFromVertical`; a rolled camera passes its own up.
    public static func angle(from: Point2, to: Point2, relativeTo up: Point2) -> Double? {
        let v = to - from
        let l = v.length
        guard l > 1e-9 else { return nil }
        return acos(min(1, max(-1, (v.x * up.x + v.y * up.y) / l))) * 180 / .pi
    }

    /// Angle between the vector `from → to` and straight up, in 0...180: 0 when `to` is directly above
    /// `from`, 90 when horizontal, 180 when directly below. Nil for a zero-length vector.
    public static func angleFromVertical(from: Point2, to: Point2) -> Double? {
        let v = to - from
        let l = v.length
        guard l > 1e-9 else { return nil }
        return acos(min(1, max(-1, v.y / l))) * 180 / .pi
    }
}
