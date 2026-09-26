// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "MacAmbientJevCore", targets: ["MacAmbientJevCore"]),
    .executable(
        name: "MacAmbientJevEvaluateSession",
        targets: ["MacAmbientJevEvaluateSession"]
    ),
    .executable(
        name: "MacAmbientJevEvaluateDiarization",
        targets: ["MacAmbientJevEvaluateDiarization"]
    )
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "MacAmbientJevCore"),
    .executableTarget(
        name: "MacAmbientJevEvaluateSession",
        dependencies: ["MacAmbientJevCore"]
    ),
    .executableTarget(
        name: "MacAmbientJevEvaluateDiarization",
        dependencies: ["MacAmbientJevCore"]
    ),
    .testTarget(
        name: "MacAmbientJevCoreTests",
        dependencies: ["MacAmbientJevCore"]
    )
]

#if os(macOS)
products += [
    .library(
        name: "MacAmbientJevAppleSupport",
        targets: ["MacAmbientJevAppleSupport"]
    ),
    .library(name: "MacAmbientJevRuntime", targets: ["MacAmbientJevRuntime"]),
    .executable(name: "MacAmbientJev", targets: ["MacAmbientJev"]),
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
    )
]

targets += [
    .target(
        name: "MacAmbientJevAppleSupport",
        dependencies: ["MacAmbientJevCore"]
    ),
    .target(
        name: "MacAmbientJevRuntime",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevAppleSupport",
            .product(name: "FluidAudio", package: "FluidAudio"),
            .product(name: "Qwen3ASR", package: "speech-swift")
        ]
    ),
    .executableTarget(
        name: "MacAmbientJev",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevRuntime"
        ]
    ),
    .executableTarget(
        name: "MacAmbientJevProcessRecording",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevRuntime",
            .product(name: "MLX", package: "mlx-swift")
        ]
    ),
    .executableTarget(
        name: "MacAmbientJevMeasureLiveLatency",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevRuntime"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevAppleSupportTests",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevAppleSupport"
        ]
    ),
    .testTarget(
        name: "MacAmbientJevRuntimeTests",
        dependencies: [
            "MacAmbientJevCore",
            "MacAmbientJevAppleSupport",
            "MacAmbientJevRuntime"
        ]
    )
]
#endif

let package = Package(
    name: "MacAmbientJev",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
