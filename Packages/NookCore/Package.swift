// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NookCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NookCore", targets: ["NookCore"]),
    ],
    targets: [
        .target(name: "NookCore", path: "Sources/NookCore"),
        .testTarget(
            name: "NookCoreTests",
            dependencies: ["NookCore"],
            path: "Tests/NookCoreTests"
        ),
    ]
)
