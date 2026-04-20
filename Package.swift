// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiteRTLM",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "LiteRTLM", targets: ["LiteRTLM"]),
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            path: "Frameworks/LiteRTLM.xcframework"
        ),
        .target(
            name: "LiteRTLM",
            dependencies: ["CLiteRTLM"],
            path: "Sources/LiteRTLM",
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "LiteRTLMTests",
            dependencies: ["LiteRTLM"],
            path: "Tests/LiteRTLMTests"
        ),
    ]
)
