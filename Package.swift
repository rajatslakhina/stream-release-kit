// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StreamReleaseKit",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "StreamReleaseKit", targets: ["StreamReleaseKit"]),
        .executable(name: "StreamReleaseDemo", targets: ["StreamReleaseDemo"])
    ],
    targets: [
        .target(
            name: "StreamReleaseKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .executableTarget(
            name: "StreamReleaseDemo",
            dependencies: ["StreamReleaseKit"],
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "StreamReleaseKitTests",
            dependencies: ["StreamReleaseKit"]
        )
    ]
)
