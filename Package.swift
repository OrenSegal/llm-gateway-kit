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
    ],
    targets: [
        .target(
            name: "LLMGatewayKit",
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
