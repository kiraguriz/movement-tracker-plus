import Foundation
import Testing
@testable import MotionCore

@Suite("Geometry")
struct GeometryTests {
    @Test("isotropic conversion scales x by the image aspect and leaves y")
    func isotropic() {
        let p = Geometry.isotropic(Keypoint(x: 0.5, y: 0.25, confidence: 1), imageAspect: 0.5625)
        #expect(abs(p.x - 0.28125) < 1e-12)
        #expect(p.y == 0.25)
    }

    @Test("equal normalized steps are unequal on screen until converted")
    func isotropicDistances() {
        // 0.1 of the width and 0.1 of the height are different lengths in a portrait image.
        let a = Geometry.isotropic(Keypoint(x: 0.5, y: 0.5, confidence: 1), imageAspect: 0.5)
        let right = Geometry.isotropic(Keypoint(x: 0.6, y: 0.5, confidence: 1), imageAspect: 0.5)
        let up = Geometry.isotropic(Keypoint(x: 0.5, y: 0.6, confidence: 1), imageAspect: 0.5)
        #expect(abs(Geometry.distance(a, right) - 0.05) < 1e-12)
        #expect(abs(Geometry.distance(a, up) - 0.10) < 1e-12)
    }

    @Test("included angle at a joint", arguments: [
        (Point2(x: 1, y: 0), Point2(x: 0, y: 0), Point2(x: 0, y: 1), 90.0),
        (Point2(x: 1, y: 0), Point2(x: 0, y: 0), Point2(x: -1, y: 0), 180.0),
        (Point2(x: 1, y: 0), Point2(x: 0, y: 0), Point2(x: 2, y: 0), 0.0),
        (Point2(x: 1, y: 0), Point2(x: 0, y: 0), Point2(x: 1, y: 1), 45.0),
        (Point2(x: 0, y: 2), Point2(x: 0, y: 1), Point2(x: 0, y: 0), 180.0),
    ])
    func includedAngle(a: Point2, vertex: Point2, c: Point2, expected: Double) throws {
        let angle = try #require(Geometry.includedAngle(at: vertex, from: a, to: c))
        #expect(abs(angle - expected) < 1e-9)
    }

    @Test("included angle is symmetric and scale-free")
    func includedAngleInvariance() throws {
        let a = Point2(x: 0.3, y: 0.7), b = Point2(x: 0.5, y: 0.4), c = Point2(x: 0.9, y: 0.45)
        let forward = try #require(Geometry.includedAngle(at: b, from: a, to: c))
        let backward = try #require(Geometry.includedAngle(at: b, from: c, to: a))
        #expect(abs(forward - backward) < 1e-9)
        let scaled = try #require(Geometry.includedAngle(at: b * 10, from: a * 10, to: c * 10))
        #expect(abs(forward - scaled) < 1e-9)
    }

    @Test("a zero-length limb has no angle")
    func degenerateAngle() {
        let p = Point2(x: 0.4, y: 0.4)
        #expect(Geometry.includedAngle(at: p, from: p, to: Point2(x: 1, y: 1)) == nil)
        #expect(Geometry.includedAngle(at: p, from: Point2(x: 1, y: 1), to: p) == nil)
    }

    @Test("angle from vertical: up is 0, sideways 90, down 180, either way")
    func angleFromVertical() throws {
        let origin = Point2(x: 0, y: 0)
        let cases: [(Point2, Double)] = [
            (Point2(x: 0, y: 1), 0), (Point2(x: 1, y: 0), 90), (Point2(x: -1, y: 0), 90),
            (Point2(x: 0, y: -1), 180), (Point2(x: 1, y: 1), 45), (Point2(x: -1, y: 1), 45),
        ]
        for (target, expected) in cases {
            let angle = try #require(Geometry.angleFromVertical(from: origin, to: target))
            #expect(abs(angle - expected) < 1e-9, "to \(target)")
        }
        #expect(Geometry.angleFromVertical(from: origin, to: origin) == nil)
    }
}

@Suite("Roles and topology")
struct RoleTests {
    @Test("slots are dense, unique and match declaration order")
    func slots() {
        #expect(Joint.count == Joint.allCases.count)
        #expect(Set(Joint.allCases.map(\.slot)) == Set(0..<Joint.count))
        for joint in Joint.allCases { #expect(Joint.ordered[joint.slot] == joint) }
    }

    @Test("roles resolve to the matching side's joint", arguments: JointRole.allCases)
    func roleResolution(role: JointRole) {
        #expect(role.joint(on: .left).side == .left)
        #expect(role.joint(on: .right).side == .right)
        #expect(role.joint(on: .left).rawValue.lowercased().hasSuffix(role.rawValue))
        #expect(role.joint(on: .right).rawValue.lowercased().hasSuffix(role.rawValue))
    }

    @Test("sides")
    func sides() {
        #expect(BodySide.left.opposite == .right)
        #expect(BodySide.right.opposite == .left)
        #expect(Joint.nose.side == nil && Joint.neck.side == nil && Joint.root.side == nil)
    }

    @Test("the skeleton touches every joint once as a connected tree")
    func skeletonTopology() {
        let bones = Skeleton.bones
        #expect(bones.count == Joint.count - 1, "a tree over 19 joints has 18 bones")
        #expect(Set(bones).count == bones.count, "no duplicate bones")
        var touched = Set<Joint>()
        for bone in bones {
            #expect(bone.from != bone.to)
            touched.insert(bone.from)
            touched.insert(bone.to)
        }
        #expect(touched == Set(Joint.allCases))

        // Connected: flood fill from the neck reaches everything.
        var adjacency: [Joint: [Joint]] = [:]
        for bone in bones {
            adjacency[bone.from, default: []].append(bone.to)
            adjacency[bone.to, default: []].append(bone.from)
        }
        var seen: Set<Joint> = [.neck]
        var stack: [Joint] = [.neck]
        while let joint = stack.popLast() {
            for next in adjacency[joint] ?? [] where seen.insert(next).inserted { stack.append(next) }
        }
        #expect(seen.count == Joint.count)
    }

    @Test("limb bones stay on their own side")
    func skeletonSides() {
        for bone in Skeleton.bones {
            if let a = bone.from.side, let b = bone.to.side { #expect(a == b, "\(bone)") }
        }
        let left = Skeleton.bones(on: .left)
        #expect(left.count == 8, "neck-shoulder, shoulder-elbow, elbow-wrist, root-hip, hip-knee, knee-ankle, nose-eye, eye-ear")
        #expect(left.allSatisfy { $0.side == .left })
        #expect(Skeleton.bones(on: .right).count == left.count)
    }
}
