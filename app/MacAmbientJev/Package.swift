// swift-tools-version: 6.0
import PackageDescription
#if os(Linux) || os(Windows)
import Foundation
#endif

var products: [Product] = [
    .library(name: "MacAmbientJevCore", targets: ["MacAmbientJevCore"]),
    .library(name: "MacAmbientJevPipeline", targets: ["MacAmbientJevPipeline"]),
    .library(name: "MacAmbientJevEngineProtocol", targets: ["MacAmbientJevEngineProtocol"]),
    .library(name: "MacAmbientJevEngineHost", targets: ["MacAmbientJevEngineHost"]),
    .library(name: "MacAmbientJevDiarization", targets: ["MacAmbientJevDiarization"]),
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
    ),
    .executable(
        name: "MacAmbientJevProcessRecording",
        targets: ["MacAmbientJevProcessRecording"]
    ),
    .executable(
        name: "MacAmbientJevEngineHarness",
        targets: ["MacAmbientJevEngineHarness"]
    )
]

#if os(Windows)
products.append(.library(
    name: "MacAmbientJevWindowsSupport",
    targets: ["MacAmbientJevWindowsSupport"]
))
#endif

var dependencies: [Package.Dependency] = []

var coreDependencies: [Target.Dependency] = ["CSHA256"]
#if os(Windows)
coreDependencies.append("CWindowsSession")
#endif

var targets: [Target] = [
    .target(name: "CSHA256", cSettings: [.unsafeFlags(["-O2"])]),
    .target(name: "MacAmbientJevCore", dependencies: coreDependencies),
    .target(name: "MacAmbientJevPipeline", dependencies: ["MacAmbientJevCore"]),
    .target(name: "MacAmbientJevEngineProtocol"),
    .target(
        name: "MacAmbientJevEngineHost",
        dependencies: ["MacAmbientJevEngineProtocol", "MacAmbientJevCore", "MacAmbientJevPipeline"],
        resources: [.copy("Resources")]
    ),
    .target(
        name: "MacAmbientJevDiarization",
        dependencies: ["MacAmbientJevCore"],
        resources: [.copy("Resources")]
    ),
    .target(
        name: "MacAmbientJevDiarizationMeasurement",
        dependencies: ["MacAmbientJevCore"]
    ),
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
    // The Mac-written canonical CAF and its expected samples, read by the CAF tests of every platform.
    .target(
        name: "MacAmbientJevCAFFixtures",
        path: "Tests/MacAmbientJevCAFFixtures",
        resources: [.copy("Resources")]
    ),
    .target(
        name: "MacAmbientJevClauseTaggerFixtures",
        path: "Tests/MacAmbientJevClauseTaggerFixtures",
        resources: [.copy("Resources")]
    ),
    // Deadline-free waits for test doubles, shared by the engine test targets.
    .target(
        name: "MacAmbientJevTestSupport",
        path: "Tests/MacAmbientJevTestSupport"
    ),
    .testTarget(
        name: "MacAmbientJevCoreTests",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevCAFFixtures",
            "MacAmbientJevClauseTaggerFixtures"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevPipelineTests",
        dependencies: ["MacAmbientJevCore", "MacAmbientJevPipeline"]
    ),
    .testTarget(
        name: "MacAmbientJevEngineProtocolTests",
        dependencies: ["MacAmbientJevEngineProtocol"],
        // The golden NDJSON is read through #filePath, so it is not a bundled resource.
        exclude: ["Fixtures"]
    ),
    .testTarget(
        name: "MacAmbientJevEngineHostTests",
        dependencies: ["MacAmbientJevEngineHost", "MacAmbientJevTestSupport"]
    ),
    .testTarget(
        name: "MacAmbientJevDiarizationMeasurementTests",
        dependencies: [
            "MacAmbientJevDiarizationMeasurement",
            "MacAmbientJevCore",
            "MacAmbientJevCAFFixtures"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevDiarizationTests",
        dependencies: ["MacAmbientJevDiarization"],
        resources: [.copy("Resources")]
    )
]

#if os(Windows)
targets.append(.target(
    name: "CMiniaudio",
    exclude: ["README.md"],
    linkerSettings: [.linkedLibrary("kernel32"), .linkedLibrary("ole32"), .linkedLibrary("uuid")]
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
    dependencies: ["MacAmbientJevCore", "MacAmbientJevPipeline", "CMiniaudio", "CWindowsAudio"]
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

#if os(Windows)
products.append(.executable(
    name: "MacAmbientJevEngine",
    targets: ["MacAmbientJevEngine"]
))
targets.append(.executableTarget(
    name: "MacAmbientJevEngine",
    dependencies: [
        "MacAmbientJevCore",
        "MacAmbientJevPipeline",
        "MacAmbientJevEngineProtocol",
        "MacAmbientJevEngineHost",
        "MacAmbientJevPortableRuntime",
        "MacAmbientJevWindowsSupport"
    ],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
targets.append(.testTarget(
    name: "MacAmbientJevEngineTests",
    dependencies: [
        "MacAmbientJevEngine",
        "MacAmbientJevCore",
        "MacAmbientJevEngineProtocol",
        "MacAmbientJevEngineHost",
        "MacAmbientJevTestSupport"
    ],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
#endif

products.append(.executable(
    name: "MacAmbientJevDiarizeFile",
    targets: ["MacAmbientJevDiarizeFile"]
))
targets.append(.executableTarget(
    name: "MacAmbientJevDiarizeFile",
    dependencies: ["MacAmbientJevCore", "MacAmbientJevDiarizationMeasurement", "MacAmbientJevPortableRuntime"],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
products.append(.library(name: "MacAmbientJevONNX", targets: ["MacAmbientJevONNX"]))
products.append(.library(name: "MacAmbientJevPortableRuntime", targets: ["MacAmbientJevPortableRuntime"]))
products.append(.executable(
    name: "MacAmbientJevTranscribeFile",
    targets: ["MacAmbientJevTranscribeFile"]
))
targets.append(.executableTarget(
    name: "MacAmbientJevTranscribeFile",
    dependencies: [
        "MacAmbientJevCore",
        "MacAmbientJevPipeline",
        "MacAmbientJevPortableRuntime",
        "MacAmbientJevONNX"
    ],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
var portableRuntimeDependencies: [Target.Dependency] = [
    "MacAmbientJevCore",
    "MacAmbientJevPipeline",
    "MacAmbientJevONNX",
    "MacAmbientJevDiarization"
]
#if os(Windows)
portableRuntimeDependencies.append("CWindowsSession")
portableRuntimeDependencies.append("MacAmbientJevWindowsSupport")
#elseif os(Linux)
portableRuntimeDependencies.append("CMiniaudio")
#endif
targets.append(.systemLibrary(name: "CONNXRuntime"))
targets.append(.target(
    name: "MacAmbientJevONNX",
    dependencies: ["CONNXRuntime", "MacAmbientJevCore"],
    // A local pinned SDK cannot use SwiftPM's binaryTarget format on Linux or Windows.
    swiftSettings: onnxRuntimeIncludeSwiftSettings,
    linkerSettings: [.unsafeFlags(onnxRuntimeLinkerFlags)]
))
targets.append(.target(
    name: "MacAmbientJevPortableRuntime",
    dependencies: portableRuntimeDependencies,
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
        "MacAmbientJevDiarization",
        "MacAmbientJevVADFixtures",
        "MacAmbientJevClauseTaggerFixtures",
        "MacAmbientJevTestSupport"
    ],
    resources: [.copy("Resources")],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
targets.append(.testTarget(
    name: "MacAmbientJevTranscribeFileTests",
    dependencies: [
        "MacAmbientJevTranscribeFile",
        "MacAmbientJevCore",
        "MacAmbientJevPortableRuntime",
        "MacAmbientJevONNX"
    ],
    swiftSettings: onnxRuntimeIncludeSwiftSettings
))
#else
let onnxRuntimeIncludeSwiftSettings: [SwiftSetting] = []
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
        name: "MacAmbientJevDiarizeFileOracle",
        targets: ["MacAmbientJevDiarizeFileOracle"]
    ),
    .executable(
        name: "MacAmbientJevCaptureSystemAudio",
        targets: ["MacAmbientJevCaptureSystemAudio"]
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
    )
]

targets += [
    .target(
        name: "MacAmbientJevAppleSupport",
        dependencies: ["MacAmbientJevCore"]
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
            "MacAmbientJevDiarization",
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
        name: "MacAmbientJevDiarizeFileOracle",
        dependencies: ["MacAmbientJevCore", "MacAmbientJevDiarizationMeasurement", "MacAmbientJevRuntime"]
    ),
    .executableTarget(
        name: "MacAmbientJevCaptureSystemAudio",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevCapture",
            "MacAmbientJevRuntime",
            "MacAmbientJevAppleSupport",
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
            "MacAmbientJevPipeline",
            "MacAmbientJevCAFFixtures",
            "MacAmbientJevClauseTaggerFixtures"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevRuntimeTests",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevRuntime",
            "MacAmbientJevDiarization",
            "MacAmbientJevVADFixtures",
            "MacAmbientJevCAFFixtures",
            .product(name: "FluidAudio", package: "FluidAudio")
        ]
    )
]
#endif

var processRecordingDependencies: [Target.Dependency] = [
    "MacAmbientJevCore",
    "MacAmbientJevPipeline"
]
var processRecordingTestDependencies: [Target.Dependency] = [
    "MacAmbientJevProcessRecording",
    "MacAmbientJevCore",
    "MacAmbientJevPipeline"
]
#if os(macOS)
processRecordingDependencies += [
    "MacAmbientJevAppleSupport",
    "MacAmbientJevRuntime",
    .product(name: "MLX", package: "mlx-swift")
]
processRecordingTestDependencies.append("MacAmbientJevRuntime")
#else
processRecordingDependencies += [
    "MacAmbientJevPortableRuntime",
    "MacAmbientJevONNX"
]
#if os(Linux)
processRecordingDependencies.append("CMiniaudio")
#elseif os(Windows)
processRecordingDependencies.append("MacAmbientJevWindowsSupport")
#endif
#endif

var processRecordingExcludes: [String] = []
var processRecordingTestExcludes: [String] = []
#if !os(macOS)
processRecordingExcludes.append("RunMonitor.swift")
processRecordingTestExcludes.append("ThermalLineTests.swift")
#endif

targets += [
    .executableTarget(
        name: "MacAmbientJevProcessRecording",
        dependencies: processRecordingDependencies,
        exclude: processRecordingExcludes,
        swiftSettings: onnxRuntimeIncludeSwiftSettings
    ),
    .testTarget(
        name: "MacAmbientJevProcessRecordingTests",
        dependencies: processRecordingTestDependencies,
        exclude: processRecordingTestExcludes,
        swiftSettings: onnxRuntimeIncludeSwiftSettings
    )
]

var engineE2ESupportDependencies: [Target.Dependency] = [
    "MacAmbientJevCore",
    "MacAmbientJevPipeline",
    "MacAmbientJevEngineHost",
    "MacAmbientJevEngineProtocol"
]
#if os(Windows)
engineE2ESupportDependencies.append("MacAmbientJevWindowsSupport")
#elseif os(macOS)
engineE2ESupportDependencies.append("MacAmbientJevAppleSupport")
#endif

var engineHarnessDependencies: [Target.Dependency] = [
    "MacAmbientJevEngineE2ESupport",
    "MacAmbientJevCore",
    "MacAmbientJevPipeline",
    "MacAmbientJevEngineHost",
    "MacAmbientJevEngineProtocol"
]
#if os(Linux) || os(Windows)
engineHarnessDependencies.append("MacAmbientJevPortableRuntime")
#endif

targets += [
    .target(
        name: "MacAmbientJevEngineE2ESupport",
        dependencies: engineE2ESupportDependencies,
        path: "Tests/MacAmbientJevEngineE2ESupport"
    ),
    .executableTarget(
        name: "MacAmbientJevEngineHarness",
        dependencies: engineHarnessDependencies,
        path: "Tests/MacAmbientJevEngineHarness",
        swiftSettings: onnxRuntimeIncludeSwiftSettings
    ),
    .testTarget(
        name: "MacAmbientJevEngineE2ETests",
        dependencies: [
            "MacAmbientJevEngineE2ESupport",
            "MacAmbientJevCore",
            "MacAmbientJevPipeline",
            "MacAmbientJevEngineHost",
            "MacAmbientJevEngineProtocol"
        ],
        path: "Tests/MacAmbientJevEngineE2ETests"
    )
]

let package = Package(
    name: "MacAmbientJev",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    cxxLanguageStandard: .cxx17
)
