// swift-tools-version: 6.0

import PackageDescription

// Fieldnote is built with xtool (https://xtool.sh), not Xcode: SwiftPM on Linux,
// signed and installed straight to a device. xtool expects the app — and each
// extension — to be a plain library product, with the rest described in xtool.yml.
//
// The cross-platform half of the codebase lives in the nested FieldnoteCore
// package, so it can be built and tested on Linux with no Apple SDK at all:
//
//     swift test --package-path Core
//
let package = Package(
    name: "Fieldnote",
    platforms: [
        // The floor is Apple Intelligence hardware, not iOS 27 (iPhone 15 Pro /
        // iPhone 16 or later). DeviceCapability refuses at launch on anything else.
        //
        // iOS only. The spec's macOS target is parked: xtool builds iOS, and this
        // code uses ActivityKit, BackgroundTasks and AVAudioSession, none of which
        // exist on macOS. Declaring a platform the sources cannot satisfy only means
        // the build system tries it and fails. Core still declares both.
        .iOS("27.0"),
    ],
    products: [
        // The app.
        .library(
            name: "Fieldnote",
            targets: ["Fieldnote"]
        ),
        // The Live Activity widget extension, declared under `extensions:` in
        // xtool.yml.
        .library(
            name: "FieldnoteWidgets",
            targets: ["FieldnoteWidgets"]
        ),
    ],
    dependencies: [
        // A path dependency's identity is its directory name ("Core"), not the name
        // declared in its manifest ("FieldnoteCore") — so that is what the product
        // references below have to say.
        .package(path: "Core"),
        // 0.17.5 for Nemotron 3 diarization (`Nemotron3Diarizer`) and its split
        // W8A8 bundles; see DiarizationService.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.5"),
        // Apple's Core AI language-model runtime: runs the optional Qwen3 summary model
        // through the Foundation Models API. Exact pin: a model-runtime bump is a
        // reviewed change, like a model bump.
        .package(url: "https://github.com/apple/coreai-models", exact: "1.0.0"),
    ],
    targets: [
        // Types both the app and the widget need, and that touch Apple frameworks
        // (ActivityKit) so cannot live in FieldnoteKit.
        .target(
            name: "FieldnoteShared",
            dependencies: [
                .product(name: "FieldnoteKit", package: "Core"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Fieldnote",
            dependencies: [
                "FieldnoteShared",
                .product(name: "FieldnoteKit", package: "Core"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "CoreAILM", package: "coreai-models"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FieldnoteWidgets",
            dependencies: ["FieldnoteShared"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Needs Darwin: CryptoKit and CommonCrypto. Runs on a Mac or a device, not
        // on the Linux build host. Everything that can be tested without an Apple
        // SDK lives in Core instead, on purpose.
        .testTarget(
            name: "FieldnoteTests",
            dependencies: ["Fieldnote"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
