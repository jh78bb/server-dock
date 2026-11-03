#!/bin/bash
#
# Build ServerDock's static FreeRDP xcframework, RDP milestone B.
#
# Output: Vendor/CFreeRDP.xcframework with merged static library/headers.
# Architecture: arm64, matching the Apple Silicon app.
# Disable LGPL/GPL/patent-related FFmpeg/OpenH264/x264/swscale dependencies, retaining Apache-2.0/OpenSSL for closed-source embedding.
#
# Local dependencies: cmake, optional ninja, git, and static OpenSSL libraries.
#   brew install cmake openssl@3
#
# CMake options vary by FreeRDP version; inspect WITH_* names in .freerdp-build/cmake.log on failure.
#
set -euo pipefail

# Configuration.
FREERDP_TAG="${FREERDP_TAG:-3.9.0}"          # Override with FREERDP_TAG=3.x.y.
OPENSSL_TAG="${OPENSSL_TAG:-openssl-3.5.0}"  # Build static OpenSSL from source with legacy provider for NTLM MD4/RC4.
ARCH="arm64"
DEPLOY="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.freerdp-build"                   # Intermediate artifacts, ignored by Git.
SRC="$WORK/FreeRDP"
BUILD="$WORK/build"
STAGE="$WORK/stage"                           # cmake --install output.
OSSL_SRC="$WORK/openssl"                       # OpenSSL source/build tree; static legacy provider lives under providers/.
OSSL_PREFIX="$WORK/openssl-install"            # OpenSSL install_sw output: libcrypto/libssl and headers.
OUT="$ROOT/Vendor/CFreeRDP.xcframework"
LOG="$WORK/cmake.log"

# Logging helpers match package-app.sh.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
    YLW=$'\033[33m'; BLU=$'\033[34m'; RST=$'\033[0m'
else BOLD=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; RST=""; fi
STEP=0
section() { printf '\n%s━━ %s %s━━━━━━━━━━━━━━━━━━━━%s\n' "$BOLD$BLU" "$1" "$DIM" "$RST"; }
step()    { STEP=$((STEP+1)); printf '%s[%d]%s %s\n' "$BOLD" "$STEP" "$RST" "$1"; }
info()    { printf '    %s%s%s\n' "$DIM" "$1" "$RST"; }
ok()      { printf '    %s✓%s %s\n' "$GRN" "$RST" "$1"; }
warn()    { printf '    %s⚠%s  %s\n' "$YLW" "$RST" "$1"; }
die()     { printf '\n%s✗ Failed: %s%s\n' "$BOLD$RED" "$1" "$RST" >&2; exit 1; }
run_quiet() { "$@" >>"$LOG" 2>&1; }

# ERR trap prints line/log tail on set -e failures, especially commands without explicit || die.
trap 'rc=$?; [ $rc -ne 0 ] && { printf "\n%s✗ Stopped at line %s (exit code %s)%s\n" "$BOLD$RED" "$LINENO" "$rc" "$RST" >&2;
      [ -f "$LOG" ] && { echo "--- Last 30 lines of cmake.log ---" >&2; tail -30 "$LOG" >&2; }; }' ERR

mkdir -p "$WORK"; : > "$LOG"

# Preflight.
section "Preflight"
command -v cmake >/dev/null || die "cmake is not installed: brew install cmake"
command -v git   >/dev/null || die "git is not installed"
command -v perl  >/dev/null || die "perl is not installed (required by OpenSSL Configure; included with macOS)"
# create-xcframework requires full Xcode; if CommandLineTools is selected,
# use DEVELOPER_DIR=/Applications/Xcode.app for this invocation without changing global settings or requiring sudo.
if ! xcodebuild -version >/dev/null 2>&1; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        warn "xcode-select points to CommandLineTools; using /Applications/Xcode.app for this run"
    else
        die "create-xcframework requires full Xcode: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
fi
ok "cmake：$(cmake --version | head -1)"
info "FreeRDP version: ${FREERDP_TAG}(override with FREERDP_TAG=...)"
info "OpenSSL version: ${OPENSSL_TAG}(override with OPENSSL_TAG=...)"
info "Log: $LOG"

# Static arm64 OpenSSL including the legacy provider.
# Build OpenSSL from source for static providers/liblegacy.a supplying NTLM MD4/RC4/DES.
# Homebrew provides only legacy.dylib, incompatible with this static libcrypto and awkward to dlopen.
# Use the same OPENSSL_PREFIX for FreeRDP configuration and library merging.
section "Build OpenSSL (static + legacy provider)"
OPENSSL_PREFIX="$OSSL_PREFIX"
LEGACY_A="$OSSL_SRC/providers/liblegacy.a"
if [ -f "$OPENSSL_PREFIX/lib/libcrypto.a" ] && [ -f "$LEGACY_A" ]; then
    ok "Reuse existing OpenSSL build: ${OSSL_PREFIX#$ROOT/}"
else
    if [ -d "$OSSL_SRC/.git" ]; then
        step "Reuse checkout and switch to ${OPENSSL_TAG}…"
        run_quiet git -C "$OSSL_SRC" fetch --tags --depth 1 origin "tags/$OPENSSL_TAG"
        run_quiet git -C "$OSSL_SRC" checkout -f "$OPENSSL_TAG"
    else
        step "Shallow-clone OpenSSL @${OPENSSL_TAG}…"
        run_quiet git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git "$OSSL_SRC"
    fi
    # no-shared produces providers/liblegacy.a outside install_sw; copy it from the build tree.
    # Keep legacy defaults; no-apps/no-tests/no-docs reduce build time without affecting libraries.
    step "Configure（darwin64-arm64 / no-shared）…"
    ( cd "$OSSL_SRC" && run_quiet ./Configure darwin64-arm64-cc \
        no-shared no-tests no-apps no-docs \
        --prefix="$OPENSSL_PREFIX" \
        -mmacosx-version-min="$DEPLOY" ) || die "OpenSSL Configure failed (see ${LOG})"
    step "make (parallel) + install_sw..."
    run_quiet make -C "$OSSL_SRC" -j"$(sysctl -n hw.ncpu)"
    run_quiet make -C "$OSSL_SRC" install_sw
    [ -f "$LEGACY_A" ] || die "Static legacy provider was not generated: ${LEGACY_A#$ROOT/}(the OpenSSL version or build layout may have changed)"
    ok "OpenSSL ready: libcrypto.a / libssl.a / liblegacy.a"
fi
info "legacy provider：${LEGACY_A#$ROOT/}"

# liblegacy.a omits ossl_legacy_provider_init: no-shared includes only algorithms
# such as md4/rc4/des, excluding legacyprov.c's module entry point.
# Compile separately with -DSTATIC_LEGACY to rename OSSL_provider_init to ossl_legacy_provider_init.
# The C bridge references it through OSSL_PROVIDER_add_builtin; merge the object into the static archive too.
LEGACYPROV_O="$WORK/legacyprov.o"
step "Compile legacy provider entry point (-DSTATIC_LEGACY)..."
( cd "$OSSL_SRC" && cc -arch "$ARCH" -mmacosx-version-min="$DEPLOY" -DSTATIC_LEGACY \
    -Iinclude -Iproviders/implementations/include -Iproviders/common/include -I. \
    -c providers/legacyprov.c -o "$LEGACYPROV_O" ) >>"$LOG" 2>&1 \
    || die "Failed to compile legacyprov.c (see ${LOG})"
nm "$LEGACYPROV_O" 2>/dev/null | grep -q "ossl_legacy_provider_init" \
    || die "legacyprov.o does not export ossl_legacy_provider_init (STATIC_LEGACY or the source layout may have changed)"
ok "Legacy entry point ready: ossl_legacy_provider_init"

# Fetch sources.
section "Fetch FreeRDP sources"
if [ -d "$SRC/.git" ]; then
    step "Reuse checkout and switch to tag ${FREERDP_TAG}…"
    run_quiet git -C "$SRC" fetch --tags --depth 1 origin "tags/$FREERDP_TAG"
    run_quiet git -C "$SRC" checkout -f "$FREERDP_TAG"
else
    step "Shallow-clone FreeRDP @${FREERDP_TAG}…"
    run_quiet git clone --depth 1 --branch "$FREERDP_TAG" https://github.com/FreeRDP/FreeRDP.git "$SRC"
fi
ok "Sources ready: ${SRC#$ROOT/}"

# CMake configuration.
section "Configure CMake (static / arm64 / without GPL-LGPL dependencies)"
step "cmake configure…"
rm -rf "$BUILD" "$STAGE"
# Key options:
# BUILD_SHARED_LIBS=OFF creates static libraries.
# WITH_SAMPLE/SERVER/CLIENT_* disables sample/server apps and builds libraries only.
# WITH_FFMPEG/SWSCALE/...=OFF excludes LGPL/GPL/patent codecs, retaining Apache/OpenSSL.
# WITH_X11/WAYLAND/SDL/MAC=OFF excludes platform clients; the app renders itself.
# Disable peripherals/audio/smartcards for minimal connection support.
run_quiet cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -DCMAKE_C_FLAGS="-fno-lto" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DWITH_SAMPLE=OFF \
    -DWITH_SERVER=OFF \
    -DWITH_PLATFORM_SERVER=OFF \
    -DWITH_CLIENT=OFF \
    -DWITH_CLIENT_SDL=OFF \
    -DWITH_CLIENT_MAC=OFF \
    -DWITH_X11=OFF \
    -DWITH_WAYLAND=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_OPENH264=OFF \
    -DWITH_X264=OFF \
    -DWITH_OPUS=OFF \
    -DWITH_FAAD2=OFF \
    -DWITH_FAAC=OFF \
    -DWITH_SOXR=OFF \
    -DWITH_JSON_DISABLED=ON \
    -DWITH_AAD=OFF \
    -DCHANNEL_RDPSND=OFF \
    -DCHANNEL_AUDIN=OFF \
    -DCHANNEL_RDPECAM=OFF \
    -DCHANNEL_URBDRC=OFF \
    -DWITH_WEBVIEW=OFF \
    -DWITH_KRB5=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_PULSE=OFF \
    -DWITH_ALSA=OFF \
    -DWITH_FUSE=OFF \
    -DWITH_LIBSYSTEMD=OFF \
    -DWITH_OPENSSL=ON \
    -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    || die "CMake configuration failed (see ${LOG}); a WITH_* option name may have changed between versions."
ok "Configuration complete"

# Compile and install.
section "Build"
step "cmake --build (parallel)..."
run_quiet cmake --build "$BUILD" --parallel "$(sysctl -n hw.ncpu)"
run_quiet cmake --install "$BUILD"
ok "Build and install complete -> ${STAGE#$ROOT/}"

# Merge static libraries.
section "Merge static libraries (FreeRDP + WinPR + OpenSSL -> one .a)"
step "Collect .a files..."
LIBS=()
while IFS= read -r f; do LIBS+=("$f"); done < <(find "$STAGE" -name 'libfreerdp*.a' -o -name 'libwinpr*.a')
[ "${#LIBS[@]}" -gt 0 ] || die "No FreeRDP/WinPR static libraries found in $STAGE (check whether the previous step produced .a files)"
# Include both legacy algorithms (liblegacy.a) and entry point (legacyprov.o).
# Otherwise ossl_legacy_provider_init is undefined and NTLM lacks MD4; libtool -static accepts archives/objects together.
LIBS+=("$OPENSSL_PREFIX/lib/libssl.a" "$OPENSSL_PREFIX/lib/libcrypto.a" "$LEGACY_A" "$LEGACYPROV_O")
for l in "${LIBS[@]}"; do info "$(basename "$l")"; done
MERGED="$WORK/libCFreeRDP.a"; rm -f "$MERGED"
libtool -static -o "$MERGED" "${LIBS[@]}" >>"$LOG" 2>&1 || die "libtool merge failed (see ${LOG})"
ok "Merged -> $(du -h "$MERGED" | cut -f1) libCFreeRDP.a"

# Assemble xcframework.
section "Assemble xcframework"
step "Collect headers..."
HDR="$WORK/headers"; rm -rf "$HDR"; mkdir -p "$HDR"
cp -R "$STAGE/include/." "$HDR/"            # Versioned include directories such as freerdp3/ and winpr3/.
cp -R "$OPENSSL_PREFIX/include/." "$HDR/"   # openssl/ headers let the C bridge include openssl/provider.h and register the legacy provider.
# Omit module.modulemap; ObjC uses project HEADER_SEARCH_PATHS for freerdp3/winpr3
# and direct #import headers, linking static symbols. Empty modulemaps create empty Clang modules/warnings.
step "xcodebuild -create-xcframework…"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
    -library "$MERGED" -headers "$HDR" \
    -output "$OUT" >>"$LOG" 2>&1 || die "create-xcframework failed (see ${LOG})"
ok "xcframework → ${OUT#$ROOT/}"

# Verify output.
section "Verify"
LIBIN="$(find "$OUT" -name '*.a' | head -1)"
info "Architecture: $(lipo -archs "$LIBIN" 2>/dev/null)"
info "freerdp_new symbols: $(nm "$LIBIN" 2>/dev/null | grep -c 'freerdp_new' || echo 0)(expected >=1)"
printf '%s✓ Done%s  Output: %s\n' "$BOLD$GRN" "$RST" "${OUT#$ROOT/}"
