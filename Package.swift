// swift-tools-version: 6.2
import PackageDescription

import Foundation
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasSherpaFramework = FileManager.default.fileExists(
    atPath: packageDir + "/Frameworks/sherpa-onnx.xcframework/Info.plist"
)
let hasCloudSubscription = FileManager.default.fileExists(
    atPath: packageDir + "/Sources/Type4Me/CloudSubscription/marker"
)
let hasCppJiebaBridge = FileManager.default.fileExists(
    atPath: packageDir + "/Sources/CppJiebaBridge/marker"
)
let isDevBuild = ProcessInfo.processInfo.environment["TYPE4ME_DEV_BUILD"] == "1"

var swiftDefines: [SwiftSetting] = [.swiftLanguageMode(.v5)]
if hasSherpaFramework { swiftDefines.append(.define("HAS_SHERPA_ONNX")) }
if hasCloudSubscription { swiftDefines.append(.define("HAS_CLOUD_SUBSCRIPTION")) }
if hasCppJiebaBridge { swiftDefines.append(.define("HAS_CPPJIEBA")) }
if isDevBuild { swiftDefines.append(.define("TYPE4ME_DEV_BUILD")) }

var excludes = ["Resources", "UI/FloatingBar/LiquidGlass/LiquidGlassShaders.metal"]
if !hasCloudSubscription { excludes.append("CloudSubscription") }

var targets: [Target] = [
    .target(
        name: "Type4MeIntelliSenseCore",
        path: "Sources/Type4MeIntelliSenseCore",
        swiftSettings: swiftDefines
    ),
    .target(
        name: "Type4MeReviseCore",
        path: "Sources/Type4MeReviseCore",
        swiftSettings: swiftDefines
    ),
    .target(
        name: "Type4MeTransferCore",
        path: "Sources/Type4MeTransferCore",
        swiftSettings: swiftDefines
    ),
    .target(
        name: "Type4MeUI",
        path: "Sources/Type4MeUI",
        swiftSettings: swiftDefines
    ),
    .executableTarget(
        name: "Type4Me",
        dependencies: ["Type4MeIntelliSenseCore", "Type4MeReviseCore", "Type4MeTransferCore"]
            + (hasSherpaFramework ? ["SherpaOnnxLib"] : [])
            + (hasCppJiebaBridge ? ["CppJiebaBridge"] : []),
        path: "Sources/Type4Me",
        exclude: excludes,
        cSettings: hasSherpaFramework ? [.headerSearchPath("Bridge")] : [],
        swiftSettings: swiftDefines,
        linkerSettings: (hasSherpaFramework || hasCppJiebaBridge ? [
            .linkedLibrary("c++"),
        ] : []) + (hasSherpaFramework ? [
            .linkedFramework("Accelerate"),
            .linkedFramework("Foundation"),
        ] : []) + [
            .linkedFramework("MediaPlayer"),
        ]
    ),
    .testTarget(
        name: "Type4MeTests",
        dependencies: ["Type4Me", "Type4MeIntelliSenseCore", "Type4MeReviseCore", "Type4MeTransferCore"],
        path: "Tests/Type4MeTests",
        swiftSettings: swiftDefines
    ),
]

if hasCppJiebaBridge {
    targets.insert(
        .target(
            name: "CppJiebaBridge",
            path: "Sources/CppJiebaBridge",
            exclude: ["CPPJIEBA_LICENSE", "JIEBA_LICENSE", "PROVENANCE.md", "marker"],
            publicHeadersPath: "include",
            cxxSettings: [.headerSearchPath("vendor")]
        ),
        at: 0
    )
}

if hasSherpaFramework {
    targets.insert(
        .binaryTarget(name: "SherpaOnnxLib", path: "Frameworks/sherpa-onnx.xcframework"),
        at: 0
    )
}

let package = Package(
    name: "Type4Me",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Type4Me", targets: ["Type4Me"]),
        .library(name: "Type4MeUI", targets: ["Type4MeUI"]),
        .library(name: "Type4MeIntelliSenseCore", targets: ["Type4MeIntelliSenseCore"]),
        .library(name: "Type4MeReviseCore", targets: ["Type4MeReviseCore"]),
        .library(name: "Type4MeTransferCore", targets: ["Type4MeTransferCore"]),
    ],
    dependencies: [],
    targets: targets
)
