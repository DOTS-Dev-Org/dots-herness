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
        .executable(name: "dotsplugin", targets: ["DotsPluginTool"]),
        .library(name: "HarnessPluginKit", type: .dynamic, targets: ["HarnessPluginKit"]),
        .library(name: "HelloPlugin", type: .dynamic, targets: ["HelloPlugin"]),
        // Not linked by the app; dlopen'd on first transcription so whisper +
        // ggml/Metal never enter the launch-time dyld graph when voice is unused.
        .library(name: "WhisperVoice", type: .dynamic, targets: ["WhisperVoice"]),
    ],
    dependencies: [
        .package(url: "https://github.com/k2-fsa/sherpa-onnx.git", exact: "1.13.6"),
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
            name: "WhisperVoice",
            dependencies: ["whisper"],
            path: "Sources/WhisperVoice"
        ),
        .target(
            name: "DotsHarnessCore",
            dependencies: [
                "HarnessPluginKit",
                "PluginRuntime",
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
            ],
            path: "Sources/DotsHarnessCore",
            exclude: ["Resources/skills"],
            resources: [.process("Resources"), .copy("Resources/skills")],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Security"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("WebKit"),
            ]
        ),
        .target(
            name: "DotsHarnessUI",
            dependencies: ["HarnessPluginKit", "PluginRuntime", "DotsHarnessCore"],
            path: "Sources/DotsHarnessUI",
            resources: [.process("Resources")]
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
            ],
            path: "Sources/DotsHarness",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "DotsPluginTool",
            dependencies: ["DotsHarnessCore"],
            path: "Sources/DotsPluginTool"
        ),
        .testTarget(
            name: "HarnessPluginKitTests",
            dependencies: [
                "HarnessPluginKit",
                "PluginRuntime",
                "DotsHarnessCore",
                "DotsHarnessUI",
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
