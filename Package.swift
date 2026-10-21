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
                 traits: ["TTS", "NemoTextProcessing"])
    ],
    targets: [
        .target(name: "TalkReadCore", path: "Sources/TalkReadCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        // Swift 5 mode for the app, as in ReadAlong: AX and AppKit callbacks are not Sendable-clean.
        .executableTarget(name: "TalkRead",
                          dependencies: ["TalkReadCore", .product(name: "FluidAudio", package: "FluidAudio")],
                          path: "Sources/TalkRead", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TalkReadCLI", dependencies: ["TalkReadCore"], path: "Sources/TalkReadCLI",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TalkReadCoreTests", dependencies: ["TalkReadCore"], path: "Tests/TalkReadCoreTests",
                    swiftSettings: [.swiftLanguageMode(.v6)])
    ]
)
