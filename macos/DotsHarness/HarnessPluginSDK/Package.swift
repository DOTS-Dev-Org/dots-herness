// swift-tools-version: 6.0
// Standalone SDK package for third-party Swift plugins:
//   .package(path: "<harness>/macos/DotsHarness/PluginSDK")
// Sources/HarnessPluginKit is a symlink to the kit the app itself builds.
import PackageDescription

let package = Package(
    name: "HarnessPluginSDK",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarnessPluginKit", targets: ["HarnessPluginKit"]),
    ],
    targets: [
        .target(name: "HarnessPluginKit"),
    ]
)
