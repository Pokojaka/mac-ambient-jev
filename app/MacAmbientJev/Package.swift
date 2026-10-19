// swift-tools-version: 6.0
import PackageDescription
#if os(Linux) || os(Windows)
import Foundation
#endif

var products: [Product] = [
    .library(name: "MacAmbientJevCore", targets: ["MacAmbientJevCore"]),
    .library(name: "MacAmbientJevPipeline", targets: ["MacAmbientJevPipeline"]),
    .executable(
        name: "MacAmbientJevEvaluateSession",
        targets: ["MacAmbientJevEvaluateSession"]
    ),
    .executable(
        name: "MacAmbientJevEvaluateDiarization",
        targets: ["MacAmbientJevEvaluateDiarization"]
    ),
    .executable(
        name: "MacAmbientJevEvaluateASR",
        targets: ["MacAmbientJevEvaluateASR"]
    )
]

#if os(Windows)
products.append(.library(
    name: "MacAmbientJevWindowsSupport",
    targets: ["MacAmbientJevWindowsSupport"]
))
#endif

var dependencies: [Package.Dependency] = []

var coreDependencies: [Target.Dependency] = []
#if os(Windows)
coreDependencies.append("CWindowsSession")
#endif

var targets: [Target] = [
    .target(name: "MacAmbientJevCore", dependencies: coreDependencies),
    .target(name: "MacAmbientJevPipeline", dependencies: ["MacAmbientJevCore"]),
    .executableTarget(
        name: "MacAmbientJevEvaluateSession",
        dependencies: ["MacAmbientJevCore"]
    ),
    .executableTarget(
        name: "MacAmbientJevEvaluateDiarization",
        dependencies: ["MacAmbientJevCore"]
    ),
    .executableTarget(
        name: "MacAmbientJevEvaluateASR",
        dependencies: ["MacAmbientJevCore"]
    ),
    // Test inputs shared by the VAD tests of every platform; no production target depends on it.
    .target(
        name: "MacAmbientJevVADFixtures",
        dependencies: ["MacAmbientJevCore"],
        path: "Tests/MacAmbientJevVADFixtures",
        exclude: ["vad_parity.json"]
    ),
    .testTarget(
        name: "MacAmbientJevCoreTests",
        dependencies: ["MacAmbientJevCore"]
    ),
    .testTarget(
        name: "MacAmbientJevPipelineTests",
        dependencies: ["MacAmbientJevCore", "MacAmbientJevPipeline"]
    )
]

#if os(Windows)
targets.append(.target(
    name: "CMiniaudio",
    exclude: ["README.md"],
    linkerSettings: [.linkedLibrary("ole32"), .linkedLibrary("uuid")]
))
#elseif os(Linux)
targets.append(.target(
    name: "CMiniaudio",
    exclude: ["README.md"],
    linkerSettings: [.linkedLibrary("m"), .linkedLibrary("dl"), .linkedLibrary("pthread")]
))
#endif

#if os(Windows)
targets.append(.target(name: "CWindowsSession", linkerSettings: [.linkedLibrary("ole32"), .linkedLibrary("shell32"), .linkedLibrary("uuid")]))
targets.append(.target(
    name: "CWindowsAudio",
    linkerSettings: [
        .linkedLibrary("mfplat"),
        .linkedLibrary("mfreadwrite"),
        .linkedLibrary("mfuuid"),
        .linkedLibrary("ole32"),
        .linkedLibrary("uuid")
    ]
))
targets.append(.target(
    name: "MacAmbientJevWindowsSupport",
    dependencies: ["MacAmbientJevCore", "CMiniaudio", "CWindowsAudio"]
))
targets.append(.testTarget(
    name: "MacAmbientJevWindowsSupportTests",
    dependencies: ["MacAmbientJevWindowsSupport", "MacAmbientJevCore", "CMiniaudio"],
    resources: [.copy("Resources")]
))
#endif

#if os(Linux) || os(Windows)
let onnxRuntimeVersion = "1.31.0"
let onnxRuntimePlatform: String
#if os(Linux)
#if arch(x86_64)
onnxRuntimePlatform = "linux-x64"
#elseif arch(arm64)
onnxRuntimePlatform = "linux-aarch64"
#else
fatalError("ONNX Runtime \(onnxRuntimeVersion) は Linux x86_64 / arm64 のみ対応します。")
#endif
#elseif os(Windows)
#if arch(x86_64)
onnxRuntimePlatform = "win-x64"
#elseif arch(arm64)
onnxRuntimePlatform = "win-arm64"
#else
fatalError("ONNX Runtime \(onnxRuntimeVersion) は Windows x86_64 / arm64 のみ対応します。")
#endif
#endif

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let onnxRuntimeRoot = repositoryRoot
    .appendingPathComponent(".build", isDirectory: true)
    .appendingPathComponent("onnxruntime", isDirectory: true)
    .appendingPathComponent(onnxRuntimeVersion, isDirectory: true)
    .appendingPathComponent("onnxruntime-\(onnxRuntimePlatform)-\(onnxRuntimeVersion)", isDirectory: true)
let onnxRuntimeIncludeDirectory = onnxRuntimeRoot.appendingPathComponent("include", isDirectory: true)
let onnxRuntimeHeader = onnxRuntimeIncludeDirectory.appendingPathComponent("onnxruntime_c_api.h")
let onnxRuntimeLibraryDirectory = onnxRuntimeRoot.appendingPathComponent("lib", isDirectory: true)
#if os(Windows)
let onnxRuntimeLibrary = onnxRuntimeLibraryDirectory.appendingPathComponent("onnxruntime.lib")
let requiredONNXRuntimeFiles = [
    onnxRuntimeHeader,
    onnxRuntimeLibrary,
    onnxRuntimeLibraryDirectory.appendingPathComponent("onnxruntime.dll")
]
#else
let onnxRuntimeLibrary = onnxRuntimeLibraryDirectory.appendingPathComponent("libonnxruntime.so.\(onnxRuntimeVersion)")
let requiredONNXRuntimeFiles = [
    onnxRuntimeHeader,
    onnxRuntimeLibrary,
    onnxRuntimeLibraryDirectory.appendingPathComponent("libonnxruntime.so.1")
]
#endif
let missingONNXRuntimeFiles = requiredONNXRuntimeFiles
    .filter { !FileManager.default.fileExists(atPath: $0.path) }
    .map { $0.path }
if !missingONNXRuntimeFiles.isEmpty {
    #if os(Windows)
    let fetchCommand = "python scripts/fetch_onnxruntime.py"
    #else
    let fetchCommand = "python3 scripts/fetch_onnxruntime.py"
    #endif
    fatalError(
        "ONNX Runtime \(onnxRuntimeVersion) の必須ファイルがありません: \(missingONNXRuntimeFiles.joined(separator: ", "))。"
            + "リポジトリルートで `\(fetchCommand)` を実行してください。"
    )
}

#if os(Windows)
let onnxRuntimeLinkerFlags = [onnxRuntimeLibrary.path]
#else
let onnxRuntimeLinkerFlags = [
    onnxRuntimeLibrary.path,
    "-Xlinker",
    "-rpath",
    "-Xlinker",
    onnxRuntimeLibraryDirectory.path
]
#endif

// The systemLibrary has no cSettings, so pass the include directory to each Swift importer.
let onnxRuntimeIncludeSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-I\(onnxRuntimeIncludeDirectory.path)"])
]

products.append(.library(name: "MacAmbientJevONNX", targets: ["MacAmbientJevONNX"]))
products.append(.library(name: "MacAmbientJevPortableRuntime", targets: ["MacAmbientJevPortableRuntime"]))
targets.append(.systemLibrary(name: "CONNXRuntime"))
targets.append(.target(
    name: "MacAmbientJevONNX",
    dependencies: ["CONNXRuntime"],
    // A local pinned SDK cannot use SwiftPM's binaryTarget format on Linux or Windows.
    swiftSettings: onnxRuntimeIncludeSwiftSettings,
    linkerSettings: [.unsafeFlags(onnxRuntimeLinkerFlags)]
))
targets.append(.target(
    name: "MacAmbientJevPortableRuntime",
    dependencies: ["MacAmbientJevCore", "MacAmbientJevPipeline", "MacAmbientJevONNX"],
    resources: [.copy("Resources")],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
targets.append(.testTarget(
    name: "MacAmbientJevONNXTests",
    dependencies: ["MacAmbientJevONNX", "MacAmbientJevVADFixtures"],
    resources: [.copy("Resources")],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
targets.append(.testTarget(
    name: "MacAmbientJevPortableRuntimeTests",
    dependencies: [
        "MacAmbientJevPortableRuntime",
        "MacAmbientJevONNX",
        "MacAmbientJevPipeline",
        "MacAmbientJevCore",
        "MacAmbientJevVADFixtures"
    ],
    resources: [.copy("Resources")],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
#endif

#if os(macOS)
products += [
    .library(
        name: "MacAmbientJevAppleSupport",
        targets: ["MacAmbientJevAppleSupport"]
    ),
    .library(name: "MacAmbientJevRuntime", targets: ["MacAmbientJevRuntime"]),
    .library(name: "MacAmbientJevCapture", targets: ["MacAmbientJevCapture"]),
    .executable(name: "MacAmbientJev", targets: ["MacAmbientJev"]),
    .executable(
        name: "MacAmbientJevCaptureSystemAudio",
        targets: ["MacAmbientJevCaptureSystemAudio"]
    ),
    .executable(
        name: "MacAmbientJevProcessRecording",
        targets: ["MacAmbientJevProcessRecording"]
    ),
    .executable(
        name: "MacAmbientJevMeasureLiveLatency",
        targets: ["MacAmbientJevMeasureLiveLatency"]
    )
]

dependencies += [
    .package(
        url: "https://github.com/FluidInference/FluidAudio.git",
        exact: "0.15.8"
    ),
    .package(
        url: "https://github.com/soniqo/speech-swift.git",
        revision: "c4c2fabbe825a9290c19e2f45d54ca3eae96b003"
    ),
    .package(
        url: "https://github.com/ml-explore/mlx-swift.git",
        exact: "0.31.6"
    ),
    .package(
        url: "https://github.com/huggingface/swift-transformers",
        exact: "1.3.4"
    )
]

targets += [
    .target(
        name: "MacAmbientJevAppleSupport",
        dependencies: [
            "MacAmbientJevCore",
            .product(name: "Tokenizers", package: "swift-transformers"),
            .product(name: "Hub", package: "swift-transformers")
        ]
    ),
    .target(
        name: "MacAmbientJevCapture",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevAppleSupport"
        ]
    ),
    .target(
        name: "MacAmbientJevRuntime",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevAppleSupport",
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "Qwen3ASR", package: "speech-swift"),
            .product(name: "MLX", package: "mlx-swift")
        ]
    ),
    .executableTarget(
        name: "MacAmbientJev",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevCapture",
            "MacAmbientJevRuntime"
        ]
    ),
    .executableTarget(
        name: "MacAmbientJevCaptureSystemAudio",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevCapture",
            "MacAmbientJevRuntime",
            .product(name: "MLX", package: "mlx-swift")
        ]
    ),
    .executableTarget(
        name: "MacAmbientJevProcessRecording",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevRuntime",
            .product(name: "MLX", package: "mlx-swift")
        ]
    ),
    .executableTarget(
        name: "MacAmbientJevMeasureLiveLatency",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevRuntime"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevProcessRecordingTests",
        dependencies: ["MacAmbientJevProcessRecording", "MacAmbientJevPipeline"]
    ),
    .testTarget(
        name: "MacAmbientJevMeasureLiveLatencyTests",
        dependencies: ["MacAmbientJevMeasureLiveLatency", "MacAmbientJevPipeline"]
    ),
    .testTarget(
        name: "MacAmbientJevAppTests",
        dependencies: [
            "MacAmbientJev",
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevCapture",
            "MacAmbientJevAppleSupport"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevCaptureTests",
        dependencies: [
            "MacAmbientJevCapture",
            "MacAmbientJevCore",
            "MacAmbientJevPipeline"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevCaptureSystemAudioTests",
        dependencies: [
            "MacAmbientJevCaptureSystemAudio",
            "MacAmbientJevCore",
            "MacAmbientJevPipeline"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevAppleSupportTests",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevPipeline"
        ],
        resources: [.copy("Resources/ClauseTaggerFixtures.json")]
    ),
    .testTarget(
        name: "MacAmbientJevRuntimeTests",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevRuntime",
            "MacAmbientJevVADFixtures"
        ]
    )
]
#endif

let package = Package(
    name: "MacAmbientJev",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    cxxLanguageStandard: .cxx17
)
