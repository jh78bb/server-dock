// swift-tools-version:5.6

import PackageDescription

let package = Package(
  name: "CryptoSwift",
  platforms: [
    .macOS(.v10_13), .macCatalyst(.v13), .iOS(.v11), .tvOS(.v11), .watchOS(.v4), .custom("visionos", versionString: "1.0")
  ],
  products: [
    .library(
      name: "CryptoSwift",
      targets: ["CryptoSwift"]
    )
  ],
  targets: [
    .target(name: "CryptoSwiftResources", resources: [ Resource.copy("PrivacyInfo.xcprivacy") ]),
    .target(name: "CryptoSwift",
            dependencies: [ .target(name: "CryptoSwiftResources", condition: .when(platforms: [ .iOS, .macOS, .tvOS, .watchOS, .macCatalyst, .visionOS ])) ],
            // ServerDock enables optimization even in Debug: RoyalVNCKit's macOS Screen Sharing ARD authentication uses Swift BigUInt
            // for 4096-bit exponentiation, taking over 30s unoptimized versus about 1s in Release.
            swiftSettings: [ .unsafeFlags(["-O"], .when(configuration: .debug)) ])
  ],
  swiftLanguageVersions: [.v5]
)
