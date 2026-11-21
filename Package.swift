// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LLMGatewayKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "LLMGatewayKit", targets: ["LLMGatewayKit"]),
        // Foundation only.
        .library(name: "LLMPricing", targets: ["LLMPricing"]),
    ],
    targets: [
        .target(
            name: "LLMPricing",
            path: "Sources/LLMPricing"
        ),
        .target(
            name: "LLMGatewayKit",
            dependencies: ["LLMPricing"],
            path: "Sources/LLMGatewayKit"
        ),
        .executableTarget(
            name: "LLMGatewayKitDemo",
            dependencies: ["LLMGatewayKit"],
            path: "Sources/LLMGatewayKitDemo"
        ),
        .testTarget(
            name: "LLMGatewayKitTests",
            dependencies: ["LLMGatewayKit"],
            path: "Tests/LLMGatewayKitTests"
        ),
    ]
)
