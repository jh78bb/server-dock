// swift-tools-version: 5.9
// Vendored copy fixing upstream 0.12.1's inout shadowing bug only; see TextLayoutManager+Layout.swift.
// Remove development SwiftLintPlugin/tests to avoid package identity conflicts with local root dependencies.
import PackageDescription

let package = Package(
    name: "CodeEditTextView",
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "CodeEditTextView",
            targets: ["CodeEditTextView"]
        ),
    ],
    dependencies: [
        // Text mutation, storage helpers
        .package(url: "https://github.com/ChimeHQ/TextStory", from: "0.9.0"),
        // Useful data structures
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "CodeEditTextView",
            dependencies: [
                "TextStory",
                .product(name: "Collections", package: "swift-collections"),
                "CodeEditTextViewObjC"
            ]
        ),
        .target(
            name: "CodeEditTextViewObjC",
            publicHeadersPath: "include"
        ),
    ]
)
