// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TalkRead",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "TalkRead", targets: ["TalkRead"]),
        .executable(name: "TalkReadCLI", targets: ["TalkReadCLI"])
    ],
    dependencies: [
        // Pinned to upstream main (macOS 27 Kokoro v3 NaN fix, #1038); see PLAN.md decision 2.
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "c79c4106b954f81205113c3343e5a7e59a1089b5",
                 traits: ["TTS", "NemoTextProcessing"]),
        // Qwen3-TTS and Breeze through MLX: mlx-audio-swift 013853a7 vendored with the Breeze patches (PLAN 0.4.0
        // decision 1; upstream has no tags); mlx-swift exact.
        .package(path: "Vendor/mlx-audio-swift"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3")
    ],
    targets: [
        .target(name: "TalkReadCore", path: "Sources/TalkReadCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        // Catches the Objective-C exceptions AVFAudio raises instead of returning errors (Player.play).
        .target(name: "ObjCExceptionCatch", path: "Sources/ObjCExceptionCatch"),
        // Swift 5 mode for the app, as in ReadAlong: AX and AppKit callbacks are not Sendable-clean.
        .executableTarget(name: "TalkRead",
                          dependencies: ["TalkReadCore", "ObjCExceptionCatch", .product(name: "FluidAudio", package: "FluidAudio"),
                                         .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
                                         .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                                         .product(name: "MLX", package: "mlx-swift")],
                          path: "Sources/TalkRead", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TalkReadCLI", dependencies: ["TalkReadCore"], path: "Sources/TalkReadCLI",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TalkReadCoreTests", dependencies: ["TalkReadCore"], path: "Tests/TalkReadCoreTests",
                    swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
