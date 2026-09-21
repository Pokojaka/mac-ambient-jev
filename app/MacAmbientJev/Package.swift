// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacAmbientJev",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MacAmbientJevCore", targets: ["MacAmbientJevCore"])
    ],
    targets: [
        .target(name: "MacAmbientJevCore"),
        .testTarget(
            name: "MacAmbientJevCoreTests",
            dependencies: ["MacAmbientJevCore"]
        )
    ]
)
