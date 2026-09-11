// swift-tools-version: 6.0

import PackageDescription

// The cross-platform half of Fieldnote: transcript alignment, chunking, grounding,
// date resolution, export formats and the policy checks.
//
// No AVFoundation, no Speech, no FoundationModels, no SwiftData, no CoreGraphics —
// so it builds and tests on a plain Linux Swift toolchain, with no Apple SDK and no
// device:
//
//     swift test --package-path Core
//
// That is the point. These are the parts where a bug is silent (a speaker label off
// by one span, a citation resolving to the wrong line, a chunk boundary eating a
// decision), and they are the parts a compiler on Linux can still check.
let package = Package(
    name: "FieldnoteCore",
    platforms: [
        .iOS("27.0"),
        .macOS("27.0"),
    ],
    products: [
        .library(
            name: "FieldnoteKit",
            targets: ["FieldnoteKit"]
        ),
    ],
    targets: [
        .target(
            name: "FieldnoteKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FieldnoteKitTests",
            dependencies: ["FieldnoteKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
