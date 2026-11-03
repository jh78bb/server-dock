# Release guide

[README](../README.md)

ServerDock is maintained for noncommercial use under [LICENSE.md](../LICENSE.md). The normal contributor workflow is to build locally and submit a pull request. This guide describes maintainer release tooling; it does not establish that a public release has been signed, notarized, or published.

## Release roadmap

The official website is [serverdock.papo.co.kr](https://serverdock.papo.co.kr/) and the intended public repository is [jh78bb/server-dock](https://github.com/jh78bb/server-dock).

CI-backed GitHub Releases are planned. Existing scripts and `.github/workflows/release.yml` are scaffolding to configure and validate, rather than evidence of a working release pipeline. The rollout should cover pull request compilation, release builds, signing/notarization, artifact uploads to GitHub Releases, and verification of update delivery.

Mac App Store distribution is also a goal if the sandbox build and submission requirements can be met. Keep that validation track alongside direct distribution; use [APP_STORE.md](APP_STORE.md) to record progress.

Before the first CI release:

- [ ] Point `origin` and public app/website links to `jh78bb/server-dock`.
- [ ] Confirm the credential-free pull request build (`.github/workflows/ci.yml`) passes on the runner.
- [ ] Configure repository release secrets, signing identities, and hosting destinations.
- [ ] Align Sparkle feed metadata and verification keys with the new repository/delivery setup.
- [ ] Verify a complete tag-triggered build, notarization, GitHub Release upload, and update check.
- [ ] Link the verified release from the official website.

## Automated builds

- **`.github/workflows/ci.yml`**: on every pull request and push to `main`, a `macos-15` runner generates the project with XcodeGen and runs an unsigned Debug build. It needs no secrets, so it also runs for forks. It checks compilation only.
- **`.github/workflows/release.yml`**: a pushed `v*` tag builds, signs with Developer ID, notarizes and staples, creates the DMG and Sparkle ZIP, publishes a GitHub Release, and publishes the appcast to GitHub Pages. It stops early if a required secret is missing.

Neither workflow has been run end to end yet. Verify them on the intended repository before relying on them.

## Distribution paths

| Purpose | Tool / target | Result |
|---|---|---|
| Use on your own Mac | `scripts/install-local.sh` | Local ad-hoc signed app installed in `/Applications` |
| Package an app | `scripts/package-app.sh` / `ServerDock` | Archive and distribution artifacts; signing/notarization depend on release configuration |
| Publish a release | `scripts/release.sh` and `.github/workflows/release.yml` | Version commit and tag; a pushed `v*` tag triggers the existing workflow; CI configuration/validation is planned |
| Validate the sandbox target | `ServerDock-MAS` | Separate build path; see [APP_STORE.md](APP_STORE.md) |

A local ad-hoc signature is not a Developer ID signature or Apple notarization. Check each published artifact and its release notes before describing it as notarized.

## Before publishing

- Complete the license/notice work in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), retaining the upstream application notice.
- Review source, screenshots, exports, logs, and commit metadata for private information.
- Compile the direct target, then manually check the connections and workflows affected by the release. Record the Xcode version and checks in the release notes.
- Confirm `origin`, the intended release branch, and release destination. Review the version and notes before pushing a tag.

## Configuration for maintainers and forks

The current release setup contains repository-specific configuration. Review these locations before attempting publication from another account:

| Setting | Location |
|---|---|
| Signing team and identities | `project.yml`, `scripts/package-app.sh`, `.github/workflows/release.yml` (`TEAM_ID`) |
| Notarization profile name | `.github/workflows/release.yml` (`NOTARY_PROFILE`), `scripts/package-app.sh` |
| Bundle identifier (`com.kavaz.serverdock`) and entitlements | `project.yml`, `ServerDock/Info.plist`, the two root entitlement files |
| Sparkle update feed and public verification key | `ServerDock/Info.plist`; workflow feed validation and appcast generation |
| Release repository, Pages feed and download hosting | `.github/workflows/release.yml`, `appcast.xml`, repository links in documents and the app |

A fork needs its own credentials, update signing keys, and hosting. Changing a bundle identifier or app signature may affect settings migration and Keychain access; verify access before distributing a changed identity.

The current workflow reads these repository secrets: `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`, `KEYCHAIN_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, and `SPARKLE_ED_PRIVATE_KEY`. `APPLE_ID` and `APPLE_APP_PASSWORD` (an app-specific password) are used by `notarytool`; the Apple Developer Program is required for the Developer ID certificate. Release files are published to GitHub Releases and the Sparkle feed to GitHub Pages (`gh-pages`); no external storage is used. Its `GITHUB_TOKEN` is supplied by Actions. Keep credential values in the appropriate secret store, never in source, release notes, screenshots, or example commands. Contributors do not need these credentials.

## Versions and publication

`ServerDock/Info.plist` is the version source: `CFBundleShortVersionString` is the display version and `CFBundleVersion` is an increasing build number. Do not duplicate the version in `project.yml`.

The release helper reads new version numbers interactively, prepares a commit, and pushes the branch and an annotated `v<version>` tag after its confirmation steps. The existing tag workflow is designed for building, signing, notarization, packaging, GitHub Release creation, and configured feed/hosting publication once CI is configured and verified. It is not a local build command.

To inspect the proposed steps, use `./scripts/release.sh --dry-run`. Dry-run still prompts for version input and checks repository state, but does not commit or push. Do not run the normal helper just to test a build.

After publication, check the downloadable artifacts, signature/notarization results, release notes, and Sparkle update behavior. A successful compilation alone does not verify these steps.
