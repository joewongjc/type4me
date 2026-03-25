// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Type4Me",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.0"),
    ],
    targets: [
        .executableTarget(
            name: "Type4Me",
            dependencies: [
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Type4Me",
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "Type4MeTests",
            dependencies: ["Type4Me"],
            path: "Type4MeTests"
        ),
    ]
)
