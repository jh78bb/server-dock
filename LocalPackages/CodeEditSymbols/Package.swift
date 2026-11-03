// swift-tools-version: 5.5

import PackageDescription

// The vendored manifest fixes CodeEditSymbols 0.2.3 omitting Symbols.xcassets from resources.
// Xcode handles asset catalogs automatically, but swift build otherwise omits Bundle.module.
// Declare resources explicitly and remove test-only SnapshotTesting so swift build packages correctly.
let package = Package(
    name: "CodeEditSymbols",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "CodeEditSymbols",
            targets: ["CodeEditSymbols"]),
    ],
    targets: [
        .target(
            name: "CodeEditSymbols",
            resources: [.process("Symbols.xcassets")]
        ),
    ]
)
