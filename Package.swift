// swift-tools-version: 6.0
import PackageDescription

// SwiftPM is the single source of truth for the build. Open Package.swift directly in
// Xcode for IDE debugging; the shipping macOS app bundle is assembled by
// scripts/run-macos.sh.
//
// Prerequisite: run scripts/build-whisper.sh once before `swift build`. It compiles
// whisper.cpp into static libraries and stages its headers into Sources/CWhisper.

/// Static libraries produced by scripts/build-whisper.sh, plus the frameworks the
/// ggml backends need. Paths are relative to the package root, which is where SwiftPM
/// runs the linker from.
let whisperLinkerSettings: [LinkerSetting] = [
    .unsafeFlags([
        "-LVendor/whisper.cpp/build/src",
        "-LVendor/whisper.cpp/build/ggml/src",
        "-LVendor/whisper.cpp/build/ggml/src/ggml-metal",
        "-LVendor/whisper.cpp/build/ggml/src/ggml-blas",
        "-lwhisper",
        "-lwhisper.coreml",
        // ggml first, then base: the backend registry in libggml references symbols
        // in libggml-base, and static link order is significant.
        "-lggml",
        "-lggml-cpu",
        "-lggml-metal",
        "-lggml-blas",
        "-lggml-base",
        "-lc++",
    ]),
    .linkedFramework("Accelerate"),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("CoreML"),
    .linkedFramework("Foundation"),
]

let package = Package(
    name: "IqraAI",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "RecitationCore", targets: ["RecitationCore"]),
    ],
    targets: [
        // Header-only shim over the prebuilt whisper.cpp libraries.
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),

        .target(
            name: "RecitationCore",
            dependencies: ["CWhisper"],
            path: "Sources/RecitationCore",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: whisperLinkerSettings
        ),
        .executableTarget(
            name: "IqraMac",
            dependencies: ["RecitationCore"],
            path: "Apps/macOS/Sources",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RecitationCoreTests",
            dependencies: ["RecitationCore"],
            path: "Tests/RecitationCoreTests",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
