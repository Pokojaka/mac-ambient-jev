// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacAmbientJev",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacAmbientJevCore", targets: ["MacAmbientJevCore"]),
        .library(name: "MacAmbientJevRuntime", targets: ["MacAmbientJevRuntime"]),
        .executable(name: "MacAmbientJev", targets: ["MacAmbientJev"]),
        .executable(
            name: "MacAmbientJevEvaluateSession",
            targets: ["MacAmbientJevEvaluateSession"]
        ),
        .executable(
            name: "MacAmbientJevProcessRecording",
            targets: ["MacAmbientJevProcessRecording"]
        ),
        .executable(
            name: "MacAmbientJevMeasureLiveLatency",
            targets: ["MacAmbientJevMeasureLiveLatency"]
        )
    ],
    dependencies: [
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
    ],
    targets: [
        .target(name: "MacAmbientJevCore"),
        .target(
            name: "MacAmbientJevRuntime",
            dependencies: [
                "MacAmbientJevCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "speech-swift")
            ]
        ),
        .executableTarget(
            name: "MacAmbientJev",
            dependencies: [
                "MacAmbientJevCore",
                "MacAmbientJevRuntime"
            ]
        ),
        .executableTarget(
            name: "MacAmbientJevEvaluateSession",
            dependencies: ["MacAmbientJevCore"]
        ),
        .executableTarget(
            name: "MacAmbientJevProcessRecording",
            dependencies: [
                "MacAmbientJevCore",
                "MacAmbientJevRuntime",
                .product(name: "MLX", package: "mlx-swift")
            ]
        ),
        .executableTarget(
            name: "MacAmbientJevMeasureLiveLatency",
            dependencies: ["MacAmbientJevCore", "MacAmbientJevRuntime"]
        ),
        .testTarget(
            name: "MacAmbientJevProcessRecordingTests",
            dependencies: ["MacAmbientJevProcessRecording"]
        ),
        .testTarget(
            name: "MacAmbientJevMeasureLiveLatencyTests",
            dependencies: ["MacAmbientJevMeasureLiveLatency"]
        ),
        .testTarget(
            name: "MacAmbientJevAppTests",
            dependencies: ["MacAmbientJev", "MacAmbientJevCore"]
        ),
        .testTarget(
            name: "MacAmbientJevCoreTests",
            dependencies: ["MacAmbientJevCore"]
        ),
        .testTarget(
            name: "MacAmbientJevRuntimeTests",
            dependencies: [
                "MacAmbientJevCore",
                "MacAmbientJevRuntime"
            ]
        )
    ]
)
