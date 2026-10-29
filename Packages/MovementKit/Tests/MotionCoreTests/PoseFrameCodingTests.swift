import Foundation
import Testing
@testable import MotionCore

@Test func poseFrameRoundTripsThroughCompactJSON() throws {
    let frame = PoseFrame(
        t: 12.5,
        joints: [.leftHip: Keypoint(x: 0.4, y: 0.5, confidence: 0.9)],
        imageAspect: 0.5625
    )
    let data = try JSONEncoder().encode(frame)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains(#""leftHip":[0.4,0.5,0.9]"#))
    #expect(try JSONDecoder().decode(PoseFrame.self, from: data) == frame)
}
