// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "screen-audio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "ScreenAudio", targets: ["ScreenAudio"]),
    ],
    targets: [
        .target(name: "ScreenAudioCore", path: "Sources/ScreenAudioCore"),
        .executableTarget(
            name: "ScreenAudio",
            dependencies: ["ScreenAudioCore"],
            path: "Sources/ScreenAudio"
        ),
        .testTarget(
            name: "ScreenAudioTests",
            dependencies: ["ScreenAudioCore"],
            path: "Tests/ScreenAudioTests"
        ),
    ]
)
