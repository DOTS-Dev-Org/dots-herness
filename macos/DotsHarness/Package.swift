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
        .executable(name: "dotsmlx", targets: ["DotsMLXServer"]),
        .library(name: "HarnessPluginKit", type: .dynamic, targets: ["HarnessPluginKit"]),
        .library(name: "HelloPlugin", type: .dynamic, targets: ["HelloPlugin"]),
        // Not linked by the app; dlopen'd on first transcription so whisper +
        // ggml/Metal never enter the launch-time dyld graph when voice is unused.
        .library(name: "WhisperVoice", type: .dynamic, targets: ["WhisperVoice"]),
    ],
    dependencies: [
        // Only the `dotsmlx` helper links these; the app never loads MLX itself.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/tree-sitter/swift-tree-sitter", from: "0.9.0"),
        .package(url: "https://github.com/simonbs/TreeSitterLanguages", exact: "0.1.10"),
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
        // C bridge that dlopens sherpa-onnx at runtime; keeps its code out of the app binary.
        .target(
            name: "PiperRuntimeC",
            path: "Sources/PiperRuntimeC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DotsHarnessCore",
            dependencies: [
                "HarnessPluginKit",
                "PluginRuntime",
                "PiperRuntimeC",
                .product(name: "SwiftTreeSitter", package: "swift-tree-sitter"),
                .product(name: "TreeSitterC", package: "treesitterlanguages"),
                .product(name: "TreeSitterCSharp", package: "treesitterlanguages"),
                .product(name: "TreeSitterGo", package: "treesitterlanguages"),
                .product(name: "TreeSitterJava", package: "treesitterlanguages"),
                .product(name: "TreeSitterJavaScript", package: "treesitterlanguages"),
                .product(name: "TreeSitterPHP", package: "treesitterlanguages"),
                .product(name: "TreeSitterPython", package: "treesitterlanguages"),
                .product(name: "TreeSitterRuby", package: "treesitterlanguages"),
                .product(name: "TreeSitterRust", package: "treesitterlanguages"),
                .product(name: "TreeSitterSwift", package: "treesitterlanguages"),
                .product(name: "TreeSitterTSX", package: "treesitterlanguages"),
                .product(name: "TreeSitterCPP", package: "treesitterlanguages"),
                .product(name: "TreeSitterTypeScript", package: "treesitterlanguages"),
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
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("CoreServices")]
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
        .executableTarget(
            name: "DotsMLXServer",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/DotsMLXServer",
            swiftSettings: [.swiftLanguageMode(.v5)]
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
