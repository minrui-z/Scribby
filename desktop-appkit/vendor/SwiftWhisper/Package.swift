// swift-tools-version:5.9
import Foundation
import PackageDescription

var exclude: [String] = []

#if os(Linux)
exclude.append("coreml")
#endif

let fileManager = FileManager.default
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let vendoredWhisperRoot = packageRoot.appendingPathComponent("whisper.cpp")
let usesModernWhisperLayout =
    fileManager.fileExists(atPath: vendoredWhisperRoot.appendingPathComponent("src/whisper.cpp").path) &&
    fileManager.fileExists(atPath: vendoredWhisperRoot.appendingPathComponent("ggml/src/ggml.c").path)

let modernWhisperSources: [String] = [
    "src/whisper.cpp",
    "ggml/src/ggml.c",
    "ggml/src/ggml.cpp",
    "ggml/src/ggml-alloc.c",
    "ggml/src/ggml-backend.cpp",
    "ggml/src/ggml-backend-reg.cpp",
    "ggml/src/ggml-backend-dl.cpp",
    "ggml/src/ggml-opt.cpp",
    "ggml/src/ggml-threading.cpp",
    "ggml/src/ggml-quants.c",
    "ggml/src/gguf.cpp",
    "ggml/src/ggml-cpu/ggml-cpu.c",
    "ggml/src/ggml-cpu/ggml-cpu.cpp",
    "ggml/src/ggml-cpu/repack.cpp",
    "ggml/src/ggml-cpu/hbm.cpp",
    "ggml/src/ggml-cpu/quants.c",
    "ggml/src/ggml-cpu/traits.cpp",
    "ggml/src/ggml-cpu/binary-ops.cpp",
    "ggml/src/ggml-cpu/unary-ops.cpp",
    "ggml/src/ggml-cpu/vec.cpp",
    "ggml/src/ggml-cpu/ops.cpp",
    "ggml/src/ggml-cpu/arch/arm/quants.c",
    "ggml/src/ggml-cpu/arch/arm/repack.cpp",
    "src/coreml/whisper-compat.m",
    "src/coreml/whisper-encoder-impl.m",
    "src/coreml/whisper-encoder.mm",
]

let modernHeaderSearchPaths = [
    ".",
    "spm-include",
    "src",
    "include",
    "ggml/include",
    "ggml/src",
    "ggml/src/ggml-cpu",
    "ggml/src/ggml-cpu/amx",
    "ggml/src/ggml-cpu/arch/arm",
    "src/coreml",
]

let versionUnsafeFlags = [
    "-DGGML_VERSION=\"1.8.4\"",
    "-DGGML_COMMIT=\"76684141a5d0\"",
    "-DWHISPER_VERSION=\"1.8.4\"",
    "-DWHISPER_COMMIT=\"76684141a5d0\"",
]

let backendCxxUnsafeFlags = [
    "-DGGML_USE_CPU",
    "-DGGML_USE_ACCELERATE",
    "-DWHISPER_USE_COREML",
    "-DWHISPER_COREML_ALLOW_FALLBACK",
    "-DACCELERATE_NEW_LAPACK",
    "-DACCELERATE_LAPACK_ILP64",
]

let commonDefines: [CSetting] = [
    .define("GGML_USE_CPU"),
    .define("GGML_USE_ACCELERATE", .when(platforms: [.macOS, .macCatalyst, .iOS])),
    .define("WHISPER_USE_COREML", .when(platforms: [.macOS, .macCatalyst, .iOS])),
    .define("WHISPER_COREML_ALLOW_FALLBACK", .when(platforms: [.macOS, .macCatalyst, .iOS])),
    .unsafeFlags(["-O3"]),
]

let modernCSettings: [CSetting] = commonDefines + [
    .define("ACCELERATE_NEW_LAPACK", .when(platforms: [.macOS, .macCatalyst, .iOS])),
    .define("ACCELERATE_LAPACK_ILP64", .when(platforms: [.macOS, .macCatalyst, .iOS])),
    .headerSearchPath("."),
    .headerSearchPath("src"),
    .headerSearchPath("include"),
    .headerSearchPath("ggml/include"),
    .headerSearchPath("ggml/src"),
    .headerSearchPath("ggml/src/ggml-cpu"),
    .headerSearchPath("ggml/src/ggml-cpu/amx"),
    .headerSearchPath("ggml/src/ggml-cpu/arch/arm"),
    .headerSearchPath("src/coreml"),
    .unsafeFlags(versionUnsafeFlags),
]

let whisperCppTarget: Target = usesModernWhisperLayout
    ? .target(
        name: "whisper_cpp",
        path: "whisper.cpp",
        sources: modernWhisperSources,
        publicHeadersPath: "spm-include",
        cSettings: modernCSettings,
        cxxSettings: modernHeaderSearchPaths.map { .headerSearchPath($0) } + [
            .unsafeFlags(versionUnsafeFlags + backendCxxUnsafeFlags),
        ],
        linkerSettings: [
            .linkedFramework("Accelerate", .when(platforms: [.macOS, .macCatalyst, .iOS])),
            .linkedFramework("CoreML", .when(platforms: [.macOS, .macCatalyst, .iOS])),
            .linkedFramework("Foundation", .when(platforms: [.macOS, .macCatalyst, .iOS])),
        ]
    )
    : .target(
        name: "whisper_cpp",
        exclude: exclude,
        cSettings: commonDefines
    )

let package = Package(
    name: "SwiftWhisper",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "SwiftWhisper", targets: ["SwiftWhisper"])
    ],
    targets: [
        .target(name: "SwiftWhisper", dependencies: [.target(name: "whisper_cpp")]),
        whisperCppTarget,
        .testTarget(name: "WhisperTests", dependencies: [.target(name: "SwiftWhisper")], resources: [.copy("TestResources/")])
    ],
    cxxLanguageStandard: CXXLanguageStandard.cxx17
)
