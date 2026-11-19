// swift-tools-version: 6.0
import PackageDescription

// The AppKit executable is macOS-only. Linux (and CI without a Mac SDK) still
// builds and tests CacheHitCore, which is the cache drawer's model.
var targets: [Target] = [
    .target(name: "CacheHitCore"),
    .testTarget(
        name: "CacheHitCoreTests",
        dependencies: ["CacheHitCore"]
    )
]
var products: [Product] = [
    .library(name: "CacheHitCore", targets: ["CacheHitCore"])
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "UsageRail",
        dependencies: ["CacheHitCore"],
        resources: [.process("Resources")]
    )
)
products.append(.executable(name: "UsageRail", targets: ["UsageRail"]))
#endif

let package = Package(
    name: "UsageRail",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
