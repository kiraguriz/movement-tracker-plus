// swift-tools-version: 6.2
import PackageDescription

// Generates the pose recordings the app replays on the Simulator, in UI tests and in demo rehearsals.
// Run `tools/replay-fixtures/generate.sh` from the repository root.
let package = Package(
    name: "replay-fixtures",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../../Packages/MovementKit"),
    ],
    targets: [
        .executableTarget(
            name: "replay-fixtures",
            dependencies: [
                .product(name: "MotionCore", package: "MovementKit"),
                .product(name: "PoseCapture", package: "MovementKit"),
            ]
        ),
    ]
)
