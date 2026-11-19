// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LeNotch",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LeNotch", targets: ["Lenotch"])],
    // Sparkle is copied into the app by build_app.sh. Models are downloaded only on request.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/altic-dev/FluidAudio.git", revision: "386f7195670b77f2954c7ee143ec63fcb50b6c3b"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .target(name: "CDockSwipe", path: "Sources/CDockSwipe", publicHeadersPath: "include",
                linkerSettings: [.linkedFramework("ApplicationServices"), .linkedLibrary("dl")]),
        .target(name: "SpacesEngine", dependencies: ["CDockSwipe"],
                swiftSettings: [.swiftLanguageMode(.v5)],
                linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("QuartzCore")]),
        // The island's state model: who holds the ears, the bubble and the card, from the
        // activities and where you are on the Mac. Pure (no AppKit), so it can be unit-tested
        // and event traces replayed.
        .target(
            name: "IslandCore",
            path: "Sources/IslandCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // What's playing: runs the vendored mediaremote-adapter (private API,
        // in Vendor/) and falls back to the players' own notifications. No AppKit.
        .target(
            name: "NowPlaying",
            path: "Sources/NowPlaying",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Lenotch",
            dependencies: [
                "IslandCore", "NowPlaying", "SpacesEngine", .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "Sources/LeNotch",
            // The shader is compiled at runtime from source (see LiquidRenderer),
            // so SwiftPM must not try to build it.
            exclude: ["Render/LiquidShape.metal"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // Sparkle.framework sits in the app's Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "IslandCoreTests",
            dependencies: ["IslandCore"],
            path: "Tests/IslandCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NowPlayingTests",
            dependencies: ["NowPlaying"],
            path: "Tests/NowPlayingTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LenotchTests",
            dependencies: ["Lenotch", "IslandCore", "SpacesEngine"],
            path: "Tests/LeNotchTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
