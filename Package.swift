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
        .executableTarget(
            name: "StudioAudioLane",
            path: "Sources/StudioAudioLane"
        )
    ]
)
