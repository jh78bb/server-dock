// swift-tools-version: 5.9
// Vendored CodeEditSourceEditor 0.15.2, included to localize hardcoded Find/Replace and context-menu strings.
// Remove upstream test targets and their swift-custom-dump dependency.
// Use sibling local CodeEditTextView and CodeEditSymbols packages, also vendored in ServerDock.
// Local paths avoid duplicate remote/local package identities, currently warnings and potentially future errors.
// Remove the SwiftLint build plugin used only by CodeEdit's own checks.
import PackageDescription

let package = Package(
    name: "CodeEditSourceEditor",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CodeEditSourceEditor", targets: ["CodeEditSourceEditor"])
    ],
    dependencies: [
        .package(path: "../CodeEditTextView"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages.git", exact: "0.1.20"),
        .package(path: "../CodeEditSymbols"),
        .package(url: "https://github.com/ChimeHQ/TextFormation", from: "0.8.2"),
    ],
    targets: [
        .target(
            name: "CodeEditSourceEditor",
            dependencies: [
                "CodeEditTextView",
                "CodeEditLanguages",
                "TextFormation",
                "CodeEditSymbols"
            ]
        ),
    ]
)
