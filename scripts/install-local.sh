#!/bin/bash
# Build from source and install an ad-hoc signed app on this Mac.
# Usage: ./scripts/install-local.sh
# Optional: CONFIGURATION=Debug ./scripts/install-local.sh
# Local use only; use package-app.sh for Developer ID / notarized distribution.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
WORK="$ROOT/.xcbuild/local-install"
APP="$WORK/Build/Products/$CONFIGURATION/ServerDock.app"
DEST="/Applications/ServerDock.app"
LOG="$WORK/build.log"
STAGE=""
INSTALL_WITH_SUDO=false

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
install_cmd() {
    if "$INSTALL_WITH_SUDO"; then sudo "$@"; else "$@"; fi
}
cleanup() {
    local rc=$?
    if [ -n "$STAGE" ]; then
        if [ ! -e "$DEST" ] && [ -d "$STAGE/previous.app" ]; then
            install_cmd mv "$STAGE/previous.app" "$DEST" || {
                printf 'Restore the previous app from: %s/previous.app\n' "$STAGE" >&2
                return "$rc"
            }
        fi
        install_cmd rm -rf "$STAGE"
    fi
}
trap cleanup EXIT

[ "$(uname -s)" = Darwin ] || die "macOS is required."
[ "$(uname -m)" = arm64 ] || die "An Apple Silicon Mac is required."
case "$CONFIGURATION" in Debug|Release) ;; *) die "CONFIGURATION must be Debug or Release." ;; esac
command -v xcodegen >/dev/null || die "Install XcodeGen first: brew install xcodegen"
xcrun --find xcodebuild >/dev/null || die "Select a full Xcode installation with xcode-select."
if pgrep -x ServerDock >/dev/null; then
    die "Quit ServerDock before installing (active connections may need saving)."
fi

mkdir -p "$WORK"
printf '[1/4] Generate Xcode project\n'
(cd "$ROOT" && xcodegen generate)

printf '[2/4] Build %s (log: %s)\n' "$CONFIGURATION" "$LOG"
# Explicit ad-hoc signing avoids selecting a revoked Apple Development identity.
if ! xcodebuild build \
    -project "$ROOT/ServerDock.xcodeproj" \
    -scheme ServerDock \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$WORK" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
    ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none \
    >"$LOG" 2>&1; then
    tail -80 "$LOG" >&2
    die "Build failed. Full log: $LOG"
fi
[ -d "$APP" ] || die "Build product not found: $APP"

printf '[3/4] Sign and verify local app\n'
# Sparkle contains executable bundles that Xcode does not sign individually.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    for child in \
        Versions/B/XPCServices/Downloader.xpc \
        Versions/B/XPCServices/Installer.xpc \
        Versions/B/Autoupdate \
        Versions/B/Updater.app; do
        [ ! -e "$SPARKLE/$child" ] || codesign --force --sign - --timestamp=none "$SPARKLE/$child"
    done
    codesign --force --sign - --timestamp=none "$SPARKLE"
fi
codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/ServerDock.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

printf '[4/4] Install to %s\n' "$DEST"
if pgrep -x ServerDock >/dev/null; then
    die "ServerDock started during the build. Quit it and rerun this script."
fi
if [ ! -w /Applications ]; then
    printf 'Administrator permission is required to write to /Applications.\n'
    sudo -v
    INSTALL_WITH_SUDO=true
fi
# Stage on the destination volume and retain the old app until verification passes.
STAGE="$(install_cmd mktemp -d /Applications/.serverdock-install.XXXXXX)"
install_cmd ditto "$APP" "$STAGE/ServerDock.app"
codesign --verify --deep --strict "$STAGE/ServerDock.app"
if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    install_cmd mv "$DEST" "$STAGE/previous.app"
fi
install_cmd mv "$STAGE/ServerDock.app" "$DEST"
printf 'Installed: %s\nLaunch: open "%s"\n' "$DEST" "$DEST"
