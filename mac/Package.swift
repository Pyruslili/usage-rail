// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageRail",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UsageRail", targets: ["UsageRail"])],
    targets: [
        .executableTarget(
            name: "UsageRail",
            resources: [.process("Resources")]
        )
    ]
)
