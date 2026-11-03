# Contributing

Thanks for your interest in ServerDock! Issues and PRs are welcome.

This project is maintained for noncommercial use; contributions do not require a paid service or maintainer release credentials.

> **License note**: ServerDock is licensed under [PolyForm Noncommercial License 1.0.0](LICENSE.md); by contributing you agree your contribution is released under the same terms.

## Reporting issues

- Search [existing issues](https://github.com/jh78bb/server-dock/issues) first
- File with the matching template; include **macOS version, ServerDock version, steps to reproduce**
- Do not report security vulnerabilities publicly — see [SECURITY.md](SECURITY.md)

## Development setup

Requires a full Xcode installation (16+), XcodeGen, and an Apple Silicon Mac. See the [README](README.md#requirements) for the verified build environment.

```bash
brew install xcodegen
git clone https://github.com/jh78bb/server-dock.git
cd server-dock
xcodegen generate            # generate the project from project.yml
xcodebuild -project ServerDock.xcodeproj -scheme ServerDock \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .xcbuild/debug CODE_SIGNING_ALLOWED=NO build   # compile without a maintainer signing certificate
```

The project is managed by [XcodeGen](https://github.com/yonaskolb/XcodeGen): **re-run `xcodegen generate` after adding/removing files**; never hand-edit `.xcodeproj`.

The unsigned command above verifies compilation only. To run the app locally, use `./scripts/install-local.sh` as described in the README; it builds, applies an ad-hoc signature, and installs the app. The direct `ServerDock` target defaults to local ad-hoc signing in Debug, so Xcode Run does not require an Apple Development certificate. App Store configurations retain their separate signing setup. Maintainer release credentials are not needed for contributions.

## Conventions

- Swift 5.9, match the surrounding style; UI uses the custom themed components (`ThemedTextField` / `PrimaryButton` …), never native modals
- Wrap user-facing strings for localization (`String(localized:)` / `Text` literals). Write them in English: the English text is the String Catalog key, and Korean goes into `ServerDock/Localizable.xcstrings`
- English is the default language for new code comments, documentation, and UI copy. Add Korean translations without replacing English source strings or changing the default language.
- Keep `README.md` as the primary English document and update `README.ko.md` when user-facing behavior or setup instructions change.
- Use Conventional Commits (`feat:` / `fix:` / `build:` …)

## Pull requests

1. Branch off `main`, keep the change focused
2. Make sure the unsigned Debug build command above passes
3. Explain the motivation and approach; link related issues
4. Attach before/after screenshots for UI changes

Do not include real server addresses, credentials, private keys, or connection exports in reports, fixtures, screenshots, or logs. Preserve upstream copyright and license notices when modifying vendored code.

## Documentation and dependency changes

Keep READMEs focused on setup and first use; put detailed workflows in `docs/FEATURES.md` and `docs/FEATURES.ko.md`. Update both languages when behavior changes. State what was actually verified rather than implying a release or App Store submission is complete.

For dependency changes, update [THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md), retain upstream license files, and describe local modifications. For documentation-only changes, check relative links and example commands; a full app build is not required unless build behavior changes. For code changes, record the build and manual checks relevant to the change.

## Local launch troubleshooting

If an older build fails to open with `CSSMERR_TP_CERT_REVOKED` or an invalid signature, regenerate with `xcodegen generate` and rebuild the direct `ServerDock` scheme in Debug. This uses local ad-hoc signing rather than a cached maintainer development certificate. To replace the installed app, quit ServerDock and run `./scripts/install-local.sh`.

`CODE_SIGNING_ALLOWED=NO` is a compilation check only. That product is not a verified launchable app bundle; use a signed Debug build or the local installer for execution.
