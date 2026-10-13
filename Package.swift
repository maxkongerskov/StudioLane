// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StudioAudioLane",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "StudioAudioLane", targets: ["StudioAudioLane"])
    ],
    targets: [
        .target(
            name: "StudioLaneCore",
            path: "Sources/StudioLaneCore"
        ),
        .executableTarget(
            name: "StudioAudioLane",
            dependencies: ["StudioLaneCore"],
            path: "Sources/StudioAudioLane"
        ),
        .testTarget(
            name: "StudioLaneCoreTests",
            dependencies: ["StudioLaneCore"],
            path: "Tests/StudioLaneCoreTests"
        )
    ]
)
