// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DotsHarness",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "DotsHarness", targets: ["DotsHarness"]),
        .executable(name: "DotsHarnessScheduler", targets: ["DotsHarnessScheduler"]),
        .executable(name: "dotsplugin", targets: ["DotsPluginTool"]),
        .library(name: "HarnessPluginKit", type: .dynamic, targets: ["HarnessPluginKit"]),
        .library(name: "FableThinkingPlugin", type: .dynamic, targets: ["FableThinkingPlugin"]),
        .library(name: "HelloPlugin", type: .dynamic, targets: ["HelloPlugin"]),
    ],
    targets: [
        .target(
            name: "HarnessPluginKit",
            path: "Sources/HarnessPluginKit"
        ),
        .target(
            name: "PluginRuntime",
            dependencies: ["HarnessPluginKit"],
            path: "Sources/PluginRuntime"
        ),
        .target(
            name: "DotsHarnessCore",
            dependencies: ["HarnessPluginKit", "PluginRuntime", "whisper"],
            path: "Sources/DotsHarnessCore",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
            ]
        ),
        .target(
            name: "DotsHarnessUI",
            dependencies: ["HarnessPluginKit", "PluginRuntime", "DotsHarnessCore"],
            path: "Sources/DotsHarnessUI",
            resources: [.process("Resources")]
        ),
        .target(
            name: "FableThinkingPlugin",
            dependencies: ["HarnessPluginKit"],
            path: "Sources/FableThinkingPlugin"
        ),
        .target(
            name: "HelloPlugin",
            dependencies: ["HarnessPluginKit"],
            path: "Examples/HelloPlugin/Sources/HelloPlugin"
        ),
        .executableTarget(
            name: "DotsHarness",
            dependencies: [
                "HarnessPluginKit",
                "PluginRuntime",
                "DotsHarnessCore",
                "DotsHarnessUI",
                "FableThinkingPlugin",
            ],
            path: "Sources/DotsHarness",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "DotsPluginTool",
            dependencies: ["DotsHarnessCore"],
            path: "Sources/DotsPluginTool"
        ),
        .executableTarget(
            name: "DotsHarnessScheduler",
            dependencies: [
                "DotsHarnessCore",
                "FableThinkingPlugin",
            ],
            path: "Sources/DotsHarnessScheduler"
        ),
        .testTarget(
            name: "HarnessPluginKitTests",
            dependencies: [
                "HarnessPluginKit",
                "PluginRuntime",
                "DotsHarnessCore",
                "FableThinkingPlugin",
            ],
            path: "Tests/HarnessPluginKitTests"
        ),
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.7.5/whisper-v1.7.5-xcframework.zip",
            checksum: "c7faeb328620d6012e130f3d705c51a6ea6c995605f2df50f6e1ad68c59c6c4a"
        ),
    ]
)
