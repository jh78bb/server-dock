#!/bin/bash
#
# Package stripped/symbol-separated ServerDock.app and branded DMG through Xcode archive.
#
# Build: Release arm64 -Osize, strip, separate dSYM.
# Outputs: dist/<version>/ServerDock.app, ServerDock-<version>.dmg, and dist/dSYMs/<version>/.
# Default ad-hoc signing; see RELEASE below for Developer ID notarization/stapling.
#
# Requires Xcode/create-dmg and a local graphical session for Finder/AppleScript layout.
#
set -Eeuo pipefail   # -E/errtrace propagates ERR traps inside run_quiet, preventing missed build.log failures.

# Configuration.
SCHEME="ServerDock"
APP_NAME="ServerDock"
VOLNAME="ServerDock"
TEAM_ID="D5KUMJQ7T8"                  # Developer ID signing/notarization team ID.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.xcbuild"                 # Intermediate artifacts, ignored by Git.
ARCHIVE="$WORK/$APP_NAME.xcarchive"
LOG="$WORK/build.log"

# Logging helpers.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""
fi
STEP=0
section() { printf '\n%s━━ %s %s━━━━━━━━━━━━━━━━━━━━%s\n' "$BOLD$BLU" "$1" "$DIM" "$RST"; }
step()    { STEP=$((STEP+1)); printf '%s[%d]%s %s\n' "$BOLD" "$STEP" "$RST" "$1"; }
info()    { printf '    %s%s%s\n' "$DIM" "$1" "$RST"; }
ok()      { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
warn()    { printf '    %s⚠%s  %s\n' "$YLW" "$RST" "$1"; }
die()     { printf '\n%s✗ Failed: %s%s\n' "$BOLD$RED" "$1" "$RST" >&2; exit 1; }

# Print line number/build-log tail on failure.
trap 'rc=$?; [ $rc -ne 0 ] && { printf "\n%s✗ Script stopped at line %s (exit code %s)%s\n" "$BOLD$RED" "$LINENO" "$rc" "$RST" >&2;
       [ -f "$LOG" ] && { echo "--- Last 120 lines of build.log ---" >&2; tail -120 "$LOG" >&2; }; }' ERR

# Log full xcodebuild output and show only terminal summaries; trap prints failures' log tails.
run_quiet() { "$@" >>"$LOG" 2>&1; }

START=$(date +%s)
mkdir -p "$WORK"; : > "$LOG"

# Preflight.
section "Preflight"
[ -d "$DEVELOPER_DIR" ] || die "Xcode not found (DEVELOPER_DIR=$DEVELOPER_DIR)"
command -v create-dmg >/dev/null || die "create-dmg is not installed; run: brew install create-dmg"
ok "Xcode：$(basename "$(dirname "$(dirname "$DEVELOPER_DIR")")")"
ok "create-dmg：$(command -v create-dmg)"
info "Build log: $LOG"

# Check signing certificate.
# Developer ID Application enables hardened-runtime/timestamp signing and notarized distribution.
# Without a certificate use local-testing ad-hoc signing; Gatekeeper blocks distribution to other Macs.
# || true avoids pipefail/set -e termination if certificate grep finds nothing.
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep -o 'Developer ID Application: [^"]*' | head -1 || true)"
NOTARY_PROFILE="${NOTARY_PROFILE:-serverdesk-notary}"   # notarytool Keychain credential profile; see the RELEASE instructions below.
NOTARIZED=false
if [ -n "$DEVID" ]; then
    ok "Signing identity: $DEVID"
else
    warn "No Developer ID Application certificate; using ad-hoc signing (local testing only)"
fi

# Archive.
section "Archive (Release / arm64 / stripped)"
step "xcodebuild archive…"
rm -rf "$ARCHIVE"
# Use Developer ID/hardened runtime/timestamp when available, otherwise ad-hoc.
if [ -n "$DEVID" ]; then
    SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVID" DEVELOPMENT_TEAM="$TEAM_ID" \
          ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp")
else
    SIGN=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="")
fi
run_quiet xcodebuild archive \
    -project "$ROOT/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$WORK/dd" \
    "${SIGN[@]}"
PRODUCT="$ARCHIVE/Products/Applications/$APP_NAME.app"
[ -d "$PRODUCT" ] || die "Archive product not found: $PRODUCT"
ok "Archive complete"

# Derive output directory from version.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PRODUCT/Contents/Info.plist")"
BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PRODUCT/Contents/Info.plist")"
DIST="$ROOT/dist/${VERSION}-${BUILDNO}"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/${APP_NAME}-${VERSION}.dmg"
mkdir -p "$DIST"

# Export artifacts.
section "Export products"
step "Export .app and dSYM..."
rm -rf "$APP"; cp -R "$PRODUCT" "$APP"
ok "App → ${APP#$ROOT/}"
if ls "$ARCHIVE/dSYMs/"*.dSYM >/dev/null 2>&1; then
    DSYM="$ROOT/dist/dSYMs/${VERSION}-${BUILDNO}"; mkdir -p "$DSYM"
    cp -R "$ARCHIVE/dSYMs/"*.dSYM "$DSYM/"
    ok "dSYM → ${DSYM#$ROOT/}"
else
    warn "dSYM not found (crash reports cannot be symbolicated)"
fi

# Re-sign nested Sparkle executables before notarization.
# Xcode's embed signing covers only the outer Sparkle.framework binary, not nested
# Updater.app/Autoupdate/XPCServices, whose shipped signatures belong to Sparkle and lack secure timestamps.
# Re-sign inside-out with this Developer ID, hardened runtime, and secure timestamps.
if [ -n "$DEVID" ]; then
    section "Re-sign nested Sparkle executables"
    SPK="$APP/Contents/Frameworks/Sparkle.framework"
    if [ -d "$SPK" ]; then
        for t in \
            "Versions/B/XPCServices/Downloader.xpc" \
            "Versions/B/XPCServices/Installer.xpc" \
            "Versions/B/Autoupdate" \
            "Versions/B/Updater.app"; do
            [ -e "$SPK/$t" ] && run_quiet codesign --force --options runtime --timestamp -s "$DEVID" "$SPK/$t"
        done
        run_quiet codesign --force --options runtime --timestamp -s "$DEVID" "$SPK"
        # Nested changes invalidate the outer seal; re-sign the app preserving entitlements.
        run_quiet codesign --force --options runtime --timestamp \
            --entitlements "$ROOT/$APP_NAME.entitlements" -s "$DEVID" "$APP"
        run_quiet codesign --verify --deep --strict "$APP"
        ok "Nested Sparkle executables and app re-signing verified"
    else
        warn "Sparkle.framework not found; skipping re-signing"
    fi
fi

# Notarize the app when Developer ID signed.
# Notarize/staple the app before packaging it, then notarize the containing DMG.
if [ -n "$DEVID" ]; then
    section "Notarize app (notarytool)"
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        step "Submit app for notarization (--wait; the first run may take a while; do not interrupt)..."
        ZIP="$WORK/app.zip"; rm -f "$ZIP"
        ditto -c -k --keepParent "$APP" "$ZIP"
        # Show live notarization progress rather than run_quiet so users do not interrupt an apparently stalled process.
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee -a "$LOG"
        xcrun stapler staple "$APP" >>"$LOG" 2>&1 \
            && { ok "App notarization and stapling complete"; NOTARIZED=true; } \
            || die "App stapling failed (notarization may have been rejected; see $LOG)"
    else
        warn "No notarytool credentials configured (profile: $NOTARY_PROFILE); skipping notarization; Developer ID signing only"
        warn "Store credentials first (one-time setup): xcrun notarytool store-credentials $NOTARY_PROFILE \\"
        warn "      --apple-id <your-Apple-ID> --team-id $TEAM_ID --password <app-specific-password>"
    fi
fi

# ── DMG ─────────────────────────────────────────────────────────────────────
section "Create DMG"
step "Generate branded background..."
run_quiet swift "$ROOT/scripts/make-dmg-background.swift" "$WORK"
BG="$WORK/background.tiff"
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$BG" >>"$LOG" 2>&1
ok "Background image (including @2x)"

step "Lay out and package with create-dmg..."
STAGE="$WORK/dmg-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"
rm -f "$DMG"
# create-dmg may return nonzero despite creating a valid image; check the output separately.
create-dmg \
    --volname "$VOLNAME" \
    --background "$BG" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 170 198 \
    --app-drop-link 490 198 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$DMG" "$STAGE" >>"$LOG" 2>&1 || true
[ -f "$DMG" ] || die "DMG was not generated (see $LOG)"
ok "DMG → ${DMG#$ROOT/}"

# Notarize the DMG after successful app notarization.
if [ "$NOTARIZED" = true ]; then
    section "Notarize DMG"
    step "Submit DMG for notarization (--wait; do not interrupt)..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee -a "$LOG"
    xcrun stapler staple "$DMG" >>"$LOG" 2>&1 && ok "DMG notarization and stapling complete" || die "DMG stapling failed (see $LOG)"
fi

# Verify output.
section "Verify"
BIN="$APP/Contents/MacOS/$APP_NAME"
codesign --verify --deep --strict --verbose=2 "$APP" >>"$LOG" 2>&1 \
    && ok "Signature verified ($([ -n "$DEVID" ] && echo "Developer ID" || echo "ad-hoc"))" \
    || warn "Signature verification failed"
if [ "$NOTARIZED" = true ]; then
    spctl --assess --type execute -vv "$APP" >>"$LOG" 2>&1 \
        && ok "Gatekeeper verification passed (notarized and stapled)" || warn "Gatekeeper verification failed (see $LOG)"
fi
WARNS=$(grep -c ": warning:" "$LOG" 2>/dev/null | tr -d ' ' || echo 0)
ELAPSED=$(( $(date +%s) - START ))

printf '\n%s──────── Build products ────────%s\n' "$BOLD" "$RST"
printf '  Version  : %s (build %s)\n' "$VERSION" "$BUILDNO"
printf '  App size : %s\n' "$(du -sh "$APP" | cut -f1)"
printf '  DMG size : %s\n' "$(du -sh "$DMG" | cut -f1)"
printf '  Arch     : %s\n' "$(lipo -archs "$BIN" 2>/dev/null)"
printf '  Signing  : %s\n' "$([ -n "$DEVID" ] && { [ "$NOTARIZED" = true ] && echo 'Developer ID + notarized (ready to distribute)' || echo 'Developer ID(not notarized)'; } || echo 'ad-hoc(local testing only)')"
printf '  Symbols  : %s %s(should be low after stripping)%s\n' "$(nm -a "$BIN" 2>/dev/null | wc -l | tr -d ' ')" "$DIM" "$RST"
printf '  Bundled dSYM: %s %s(expected 0)%s\n' "$(find "$APP" -name '*.dSYM' | wc -l | tr -d ' ')" "$DIM" "$RST"
printf '  Warnings : %s\n' "$WARNS"
printf '  Elapsed  : %ss\n' "$ELAPSED"
printf '  Output   : %s\n' "${DIST#$ROOT/}/"
printf '%s✓ Done%s\n' "$BOLD$GRN" "$RST"

# RELEASE: Developer ID notarized distribution.
# The steps above sign/notarize automatically when a Developer ID certificate exists;
# notarytool credentials enable app/DMG notarization/stapling. One-time setup:
#
# 1) Xcode > Settings > Accounts > Team > Manage Certificates
# > Plus > Developer ID Application; account-holder creation only.
#
# 2) Store notarization credentials using either method:
# a) Create an app-specific password under Apple ID > Sign-In and Security, then:
#         xcrun notarytool store-credentials $NOTARY_PROFILE \
#             --apple-id <your-Apple-ID> --team-id D5KUMJQ7T8 --password <app-specific-password>
# b) For automation prefer App Store Connect API credentials via --key/--key-id/--issuer.
#
# Later runs produce signed/notarized distribution DMGs. To change credential profile name:
#   NOTARY_PROFILE=my-profile ./scripts/package-app.sh
#
# MAS distribution instead uses Apple Distribution, App Store exportArchive, Transporter,
# and App Sandbox through a separate procedure, not this direct-distribution script.
