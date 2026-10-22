// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentScreen",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AgentScreenCore"),
        .executableTarget(name: "AgentScreen", dependencies: ["AgentScreenCore"]),
        .testTarget(name: "AgentScreenCoreTests", dependencies: ["AgentScreenCore"]),
    ],
    swiftLanguageModes: [.v5]
)
