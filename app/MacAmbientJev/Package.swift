// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacAmbientJev",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacAmbientJevCore", targets: ["MacAmbientJevCore"]),
        .executable(name: "MacAmbientJev", targets: ["MacAmbientJev"])
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
        .executableTarget(
            name: "MacAmbientJev",
            dependencies: [
                "MacAmbientJevCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Qwen3ASR", package: "speech-swift")
            ]
        ),
        .testTarget(
            name: "MacAmbientJevCoreTests",
            dependencies: ["MacAmbientJevCore"]
        )
    ]
)
