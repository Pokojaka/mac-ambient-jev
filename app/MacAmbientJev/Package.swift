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
        )
    ],
    targets: [
        .target(name: "MacAmbientJevCore"),
        .target(
            name: "MacAmbientJevRuntime",
            dependencies: [
                "MacAmbientJevCore",
                "MacAmbientJevRuntime",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "speech-swift")
            ]
        ),
        .executableTarget(
            name: "MacAmbientJev",
            dependencies: [
                "MacAmbientJevCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "speech-swift")
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
                "MacAmbientJevRuntime"
            ]
        ),
        .testTarget(
            name: "MacAmbientJevCoreTests",
            dependencies: ["MacAmbientJevCore"]
        )
    ]
)