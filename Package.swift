// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Minpod",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Minpod",
            dependencies: ["MinpodKit"],
            path: "Sources/Minpod"
        ),
        .target(
            name: "MinpodKit",
            path: "Sources/MinpodKit"
        ),
        .testTarget(
            name: "MinpodKitTests",
            dependencies: ["MinpodKit"],
            path: "Tests/MinpodKitTests"
        ),
    ]
)
