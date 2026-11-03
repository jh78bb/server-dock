# Security policy

[README](README.md) · [Contributing](CONTRIBUTING.md)

ServerDock is a community project maintained for noncommercial use. Security fixes focus on the latest release and current development branch; older versions are not maintained separately. Response and release times depend on maintainer availability.

## Report a vulnerability privately

Please use [GitHub private vulnerability reporting](https://github.com/jh78bb/server-dock/security/advisories/new). This requires the repository owner to enable private reporting. If that option is unavailable, ask [the maintainer](https://github.com/jh78bb) for a private reporting channel without posting vulnerability details publicly.

Include the affected version or commit, macOS version, build channel, steps to reproduce with dummy hosts/data, expected and actual behavior, and likely impact. Include a minimal reproduction or suggested fix if available. Do not include live credentials, private keys, real server exports, or unredacted logs.

Use [Issues](https://github.com/jh78bb/server-dock/issues) for ordinary bugs. Please coordinate disclosure with the maintainer so a fix and advisory can be prepared.

## Data and trust boundaries

- Saved connection credentials and the app's key library use Keychain. Profiles, notes, scripts, conversation history, command output, and exported files may still contain sensitive information.
- SSH Key Manager can change actual files in a user-selected directory; these are separate from the app's key library.
- Verify host keys and remote certificate fingerprints through a trusted channel. A changed fingerprint needs investigation before reconnecting.
- Remote commands and AI CLIs act with the logged-in account's permissions. Third-party CLIs and network services have their own data-handling policies.
- App Lock covers the UI; active connections, transfers, and tunnels continue running.

Please report cases where behavior differs from these boundaries. For third-party dependency issues, include the affected dependency and version if known; coordinate privately before sharing an exploit.
