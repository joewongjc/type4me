// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "IntelliSenseEval",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "intellisense-eval", targets: ["IntelliSenseEvalCLI"]),
        .library(name: "IntelliSenseEvalKit", targets: ["IntelliSenseEvalKit"]),
    ],
    dependencies: [
        .package(name: "Type4Me", path: "../.."),
    ],
    targets: [
        .target(
            name: "IntelliSenseEvalKit",
            dependencies: [
                .product(name: "Type4MeIntelliSenseCore", package: "Type4Me"),
            ],
            resources: [.copy("Fixtures")]
        ),
        .executableTarget(
            name: "IntelliSenseEvalCLI",
            dependencies: ["IntelliSenseEvalKit"]
        ),
        .testTarget(
            name: "IntelliSenseEvalKitTests",
            dependencies: ["IntelliSenseEvalKit"]
        ),
    ]
)
