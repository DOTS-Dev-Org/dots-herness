// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VisionPlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VisionPlugin", type: .dynamic, targets: ["VisionPlugin"]),
    ],
    dependencies: [
        .package(path: "../HarnessPluginSDK"),
    ],
    targets: [
        .target(
            name: "VisionPlugin",
            dependencies: [.product(name: "HarnessPluginKit", package: "HarnessPluginSDK")]
        ),
    ]
)
