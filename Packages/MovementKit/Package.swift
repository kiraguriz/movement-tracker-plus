// swift-tools-version: 6.2
import PackageDescription

// Everything here must build and test on macOS with `swift test`.
// iOS-only code (camera capture, HealthKit) sits behind `#if os(iOS)`; SwiftUI lives in the app target.
let package = Package(
    name: "MovementKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "MotionCore", targets: ["MotionCore"]),
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "PoseCapture", targets: ["PoseCapture"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "CoachKit", targets: ["CoachKit"]),
        .library(name: "HealthBridge", targets: ["HealthBridge"]),
        .executable(name: "motion-eval", targets: ["MotionEval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "MotionCore", resources: [.copy("Specs")]),
        .target(name: "Domain"),
        .target(name: "PoseCapture", dependencies: ["MotionCore"]),
        .target(name: "Persistence", dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "CoachKit", dependencies: ["Domain"]),
        .target(name: "HealthBridge", dependencies: ["Domain"]),
        .executableTarget(name: "MotionEval", dependencies: ["MotionCore", "PoseCapture"]),

        .testTarget(name: "MotionCoreTests", dependencies: ["MotionCore"]),
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "PoseCaptureTests", dependencies: ["PoseCapture", "MotionCore", "MotionEval"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "CoachKitTests", dependencies: ["CoachKit"]),
    ]
)
