# Third-party notices

[README](../README.md) · [한국어 안내](../README.ko.md#라이선스와-감사의-말)

ServerDock includes and depends on work by other authors. Each component retains its own license; the repository's PolyForm Noncommercial license does not replace those terms. This inventory records what is present and what still needs to be collected before distribution. It is not a complete replacement for upstream license texts.

## Upstream application

The application license contains this notice, which must be preserved:

Required Notice: Copyright 2026 cloudza (https://github.com/icloudza/termo)

See [LICENSE.md](../LICENSE.md) for the full application terms.

## Notices available in this repository

| Component | Local notice | Integration |
|---|---|---|
| CodeEditSourceEditor | [MIT license](../LocalPackages/CodeEditSourceEditor/LICENSE.md) | Vendored; manifest and UI strings modified for local integration and localization. |
| CodeEditTextView | [MIT license](../LocalPackages/CodeEditTextView/LICENSE.md) | Vendored package; preserve its original notices when modifying it. |
| CryptoSwift | [License and acknowledgment requirements](../LocalPackages/CryptoSwift/LICENSE) | Vendored Swift package. |
| Lucide / included Feather-derived icons | [Icon notices](../ServerDock/Resources/Licenses/Lucide.txt) | App icons; the website also includes its own notice file. |

CryptoSwift acknowledgment, reproduced as required by its license:

> This product includes software developed by the "Marcin Krzyzanowski" (http://krzyzanowskim.com/).

## Notice collection still required

| Component | Source/version reference | Remaining work |
|---|---|---|
| CodeEditSymbols | `LocalPackages/CodeEditSymbols/Package.swift` identifies the vendored integration as 0.2.3. | Restore the matching upstream license; the local copy has no standalone license file. Its manifest is modified to declare asset resources. |
| FreeRDP / WinPR | `scripts/build-freerdp.sh`, default FreeRDP tag 3.9.0 | Collect the license and applicable notices for the actual code in `Vendor/CFreeRDP.xcframework`. |
| OpenSSL | Native build scripts default to openssl-3.5.0. | Collect the exact upstream license/notices for the version statically included in FreeRDP; avoid assuming the script default proves a binary's provenance. |
| libssh2 | `scripts/build-libssh2.sh`, default libssh2-1.11.1 | Preserve the notices in the shipped headers and supply the corresponding binary redistribution notice. |
| Sparkle | `Vendor/Sparkle.framework`; release workflow downloads its configured version separately. | Identify the bundled version and collect the matching license and third-party notices, including updater helpers. |
| Remote Swift packages | `ServerDock.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` | Inventory SwiftTerm, RoyalVNCKit and all resolved transitive packages; retain their exact license/notice files in redistributed materials. |

Native build tags can be overridden. The shipped artifacts, resolved revisions, and local modifications must be checked together when completing this inventory.

## Maintaining notices

When adding or updating a dependency, record its source, resolved version/revision, license, and local modifications. Preserve full license and required notice files. Include applicable notices with the distributed app as required by each dependency, including statically linked libraries and embedded helper executables.

Noncommercial distribution still needs to comply with these conditions. The entries above remain pending until the actual texts and distribution contents have been verified.
