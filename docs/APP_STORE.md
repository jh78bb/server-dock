# Mac App Store Submission Guide

**English** · [한국어](APP_STORE.ko.md)

Mac App Store distribution is an additional project goal if the sandbox build and submission requirements can be met. This guide tracks the existing `ServerDock-MAS` target and the work needed for submission. CI-backed GitHub Releases are planned first; App Store validation can proceed alongside that work. The project remains maintained for noncommercial use under [LICENSE.md](../LICENSE.md).

See [RELEASING.md](RELEASING.md) for direct-distribution tooling and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency notices.

ServerDock builds two app targets from the same source.

| Distribution | Target / scheme | Configuration | Sparkle | Sandbox | Local terminal |
|---|---|---|---|---|---|
| Direct (Developer ID, GitHub) | `ServerDock` | Debug / Release | Linked and embedded | No | Available |
| Mac App Store | `ServerDock-MAS` | DebugMAS / ReleaseMAS | **Excluded** | Yes (`ServerDock-MAS.entitlements`) | Hidden |

- Build MAS: `xcodebuild -scheme ServerDock-MAS -configuration ReleaseMAS archive`.
- Direct-distribution scripts (`scripts/package-app.sh`, `scripts/release.sh`) continue to use the `ServerDock` scheme.
- Both targets take version numbers exclusively from `ServerDock/Info.plist`. The MAS post-build script removes only the `SU*` keys.
- Privacy manifest: `ServerDock/Resources/PrivacyInfo.xcprivacy`, declaring reasons for UserDefaults, file timestamps, and system boot time; no tracking or data collection.
- In the sandbox, SSH Key Manager stores a security-scoped bookmark for the user-selected `.ssh` folder to retain access after relaunch.

## Draft App Review Notes

Use in App Store Connect › App Review Information › Notes.

> ServerDock is an SSH / SFTP / Remote Desktop client for developers and system administrators.
> It does not require a ServerDock account. Connection profiles and history are stored locally; credentials use macOS Keychain. To try it, add a host with **Hosts › Add** and connect.
>
> **Test server (please use this):**
> - Host: `<REVIEW_HOST>`  Port: `<PORT>`
> - User: `<USER>`  Password: `<PASSWORD>`
> - Remote Desktop test host (optional): `<RDP_HOST>` / `<RDP_USER>` / `<RDP_PASSWORD>`
>
> **What to try:** connect → the terminal and the file panel (right side) open together; right-click a file for Tail / editor; right-click a folder for Analyze Disk Usage; open the Host Overview for live CPU/memory/disk charts.
>
> Notes: the local terminal and the local Mac host are hidden in this sandboxed build. There is no in-app updater. The SSH Key Manager asks you to choose your `.ssh` folder once (sandbox). AI Assistant runs an AI CLI *on the user's own server* and only when the user opens it; The CLI may send prompts and server content to its provider; its behavior and permissions must be explained in the submitted build.

## Recorded Status (September 29, 2026)

This records the earlier implementation checkpoint; pending items still require validation.

- [x] Isolate Sparkle to direct-distribution builds; exclude linkage/embedding and remove `SU*` keys from `ServerDock-MAS`.
- [x] Add `PrivacyInfo.xcprivacy`.
- [x] Add sandbox folder selection/bookmark support to SSH Key Manager. Compilation was checked; actual sandbox behavior was not yet verified.
- [x] Draft App Review notes.

Next validation pass:

- [ ] Archive `ReleaseMAS` and run Validate App, including signing.
- [ ] Run `DebugMAS`, select the SSH Key Manager folder, relaunch, and verify continued access.
- [ ] Verify sandbox behavior for Tail, folder disk-usage analysis, command tools, and the snippets sidebar.
- [ ] Complete the submission checklist below.

## Before Submission

These items require configuration, review, or manual validation beyond code changes.

- [ ] Prepare a **test server** and enter credentials only in private App Store Connect review information. Keep placeholders in public documents.
- [ ] Reassess `ITSAppUsesNonExemptEncryption` (currently `false`) and confirm the applicable export classification for SSH encryption implemented with OpenSSL/libssh2.
- [ ] Configure the privacy-policy URL, support URL, and App Privacy labels against the actual build and third-party CLI behavior.
- [ ] Keep the noncommercial publication policy and verify compatibility between upstream license terms and the proposed App Store distribution.
- [ ] Include open-source notices in the app's About screen for OpenSSL, libssh2, FreeRDP, SwiftTerm, CodeEdit, and other dependencies.
- [ ] Align and verify About, privacy/support links, and website links for `jh78bb/server-dock` and `https://serverdock.papo.co.kr/`; retain the visible app name ServerDock.
- [ ] Configure Apple Distribution signing/provisioning, archive `ReleaseMAS`, and pass **Validate App** in Xcode Organizer.
- [ ] Decide whether first-use AI Assistant UI should explain that the server-side CLI may send data to an external AI service.
