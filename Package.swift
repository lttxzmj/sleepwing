// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Perch",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PerchCore", targets: ["PerchCore"]),
        .executable(name: "Perch", targets: ["Perch"]),
        .executable(name: "PerchRelay", targets: ["PerchRelay"]),
    ],
    targets: [
        .target(name: "PerchCore"),
        .executableTarget(
            name: "Perch",
            dependencies: ["PerchCore"],
            resources: [
                .copy("Resources/BrandAssets"),
                .copy("Resources/Skills"),
                .copy("Resources/perch-sleepwing-bird-v2.png"),
                .copy("Resources/perch-crescent-cat-v2.png"),
            ]
        ),
        .executableTarget(
            name: "PerchRelay",
            dependencies: ["PerchCore"]
        ),
        .testTarget(name: "PerchCoreTests", dependencies: ["PerchCore"]),
    ]
)
