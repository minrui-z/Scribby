// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribbySwiftWhisperCore",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "ScribbySwiftWhisperCore",
            targets: ["SwiftWhisperCore"]
        ),
        .executable(
            name: "scribby-swiftwhisper-headless",
            targets: ["SwiftWhisperHeadless"]
        ),
        .executable(
            name: "scribby-coreml-diagnose",
            targets: ["SwiftWhisperCoreMLDiagnose"]
        ),
    ],
    dependencies: [
        .package(
            path: "../vendor/SwiftWhisper"
        ),
    ],
    targets: [
        .target(
            name: "SwiftWhisperCore",
            dependencies: [
                .product(name: "SwiftWhisper", package: "SwiftWhisper"),
            ]
        ),
        .executableTarget(
            name: "SwiftWhisperHeadless",
            dependencies: ["SwiftWhisperCore"]
        ),
        .executableTarget(
            name: "SwiftWhisperCoreMLDiagnose",
            dependencies: ["SwiftWhisperCore"]
        ),
    ]
)
