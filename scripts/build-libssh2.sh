#!/bin/bash
#
# Build static libssh2 xcframework for the in-process engine, SSH migration J1.
#
# Output: Vendor/CSSH2.xcframework with libssh2.a and headers only.
# Architecture: arm64, matching the app.
# libssh2 BSD-3-Clause permits static closed-source embedding.
#
# Include only libssh2.a, not another OpenSSL copy.
# The app already links static OpenSSL through CFreeRDP; another copy would duplicate
# libcrypto/libssl symbols. Use the same OpenSSL headers/configuration for compilation,
# leaving undefined OpenSSL references resolved by CFreeRDP at app link time.
# Both libraries need matching OpenSSL version/ABI; reuse .freerdp-build by default.
#
# Dependencies: cmake, git, full Xcode. Reuse build-freerdp.sh's static OpenSSL
# under .freerdp-build/openssl-install, otherwise build no-shared locally.
#
set -euo pipefail

# Configuration.
LIBSSH2_TAG="${LIBSSH2_TAG:-libssh2-1.11.1}"   # Override with LIBSSH2_TAG=....
OPENSSL_TAG="${OPENSSL_TAG:-openssl-3.5.0}"    # Used only when building OpenSSL locally; keep it consistent with FreeRDP's version.
ARCH="arm64"
DEPLOY="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.libssh2-build"                    # Intermediate artifacts, ignored by Git.
SRC="$WORK/libssh2"
BUILD="$WORK/build"
STAGE="$WORK/stage"                            # cmake --install output.
OUT="$ROOT/Vendor/CSSH2.xcframework"
LOG="$WORK/cmake.log"

# Reuse FreeRDP OpenSSL for ABI consistency and less work; otherwise build in the configured directory.
OPENSSL_PREFIX="${OPENSSL_PREFIX:-$ROOT/.freerdp-build/openssl-install}"
OSSL_SELF="$WORK/openssl"                       # Source tree for a local OpenSSL build.
OSSL_SELF_PREFIX="$WORK/openssl-install"        # Install output for a local OpenSSL build.

# Logging helpers match build-freerdp.sh.
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

trap 'rc=$?; [ $rc -ne 0 ] && { printf "\n%s✗ Stopped at line %s (exit code %s)%s\n" "$BOLD$RED" "$LINENO" "$rc" "$RST" >&2;
      [ -f "$LOG" ] && { echo "--- Last 30 lines of cmake.log ---" >&2; tail -30 "$LOG" >&2; }; }' ERR

mkdir -p "$WORK"; : > "$LOG"

# Preflight.
section "Preflight"
command -v cmake >/dev/null || die "cmake is not installed: brew install cmake"
command -v git   >/dev/null || die "git is not installed"
if ! xcodebuild -version >/dev/null 2>&1; then
    if [ -d "/Applications/Xcode.app/Contents/Developer" ]; then
        export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
        warn "xcode-select points to CommandLineTools; using /Applications/Xcode.app for this run"
    else
        die "create-xcframework requires full Xcode: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
fi
ok "cmake：$(cmake --version | head -1)"
info "libssh2 version: ${LIBSSH2_TAG}(override with LIBSSH2_TAG=...)"
info "Log: $LOG"

# Reuse FreeRDP OpenSSL, otherwise build it here.
section "Locate static OpenSSL"
if [ -f "$OPENSSL_PREFIX/lib/libcrypto.a" ]; then
    ok "Reuse static OpenSSL from FreeRDP: ${OPENSSL_PREFIX#$ROOT/}"
else
    warn "Not found: ${OPENSSL_PREFIX#$ROOT/}/lib/libcrypto.a -- building locally (run build-freerdp.sh first to share its OpenSSL build)"
    command -v perl >/dev/null || die "perl is not installed (required by OpenSSL Configure; included with macOS)"
    OPENSSL_PREFIX="$OSSL_SELF_PREFIX"
    if [ -f "$OPENSSL_PREFIX/lib/libcrypto.a" ]; then
        ok "Reuse the OpenSSL build from the previous run"
    else
        if [ -d "$OSSL_SELF/.git" ]; then
            run_quiet git -C "$OSSL_SELF" fetch --tags --depth 1 origin "tags/$OPENSSL_TAG"
            run_quiet git -C "$OSSL_SELF" checkout -f "$OPENSSL_TAG"
        else
            step "Shallow-clone OpenSSL @${OPENSSL_TAG}…"
            run_quiet git clone --depth 1 --branch "$OPENSSL_TAG" https://github.com/openssl/openssl.git "$OSSL_SELF"
        fi
        step "Configure + make（darwin64-arm64 / no-shared）…"
        ( cd "$OSSL_SELF" && run_quiet ./Configure darwin64-arm64-cc \
            no-shared no-tests no-apps no-docs \
            --prefix="$OPENSSL_PREFIX" -mmacosx-version-min="$DEPLOY" ) || die "OpenSSL Configure failed (see ${LOG})"
        run_quiet make -C "$OSSL_SELF" -j"$(sysctl -n hw.ncpu)"
        run_quiet make -C "$OSSL_SELF" install_sw
        ok "OpenSSL ready (built locally)"
    fi
fi

# Fetch sources.
section "Fetch libssh2 sources"
if [ -d "$SRC/.git" ]; then
    step "Reuse checkout and switch to tag ${LIBSSH2_TAG}…"
    run_quiet git -C "$SRC" fetch --tags --depth 1 origin "tags/$LIBSSH2_TAG"
    run_quiet git -C "$SRC" checkout -f "$LIBSSH2_TAG"
else
    step "Shallow-clone libssh2 @${LIBSSH2_TAG}…"
    run_quiet git clone --depth 1 --branch "$LIBSSH2_TAG" https://github.com/libssh2/libssh2.git "$SRC"
fi
ok "Sources ready: ${SRC#$ROOT/}"

# Security patch: CVE-2026-55200 (CVSS 9.2, public proof of concept).
# ssh2_transport_read's unencrypted-length branch checks packet_length's lower bound only.
# Subsequent total_num addition can overflow and write beyond heap bounds, allowing malicious servers to execute client code.
# Other 1.11.1 branches check upper bounds; backport upstream PR #2052, touching transport.c only.
# Patch the pinned tag until an upstream fixed release is used; reset checkout and reapply each build.
section "Apply security patch CVE-2026-55200"
TP="$SRC/src/transport.c"
[ -f "$TP" ] || die "Not found: $TP"
# Nonmutating check expects exactly one unbraced vulnerable branch; fixed "< 1) {" branches do not match.
VULN=$(perl -0777 -ne 'print scalar(() = /if\(p->packet_length < 1\)\n\s+return LIBSSH2_ERROR_DECRYPT;/g)' "$TP")
if [ "$VULN" = "1" ]; then
    perl -0777 -i -pe 's{if\(p->packet_length < 1\)\n(\s+)return LIBSSH2_ERROR_DECRYPT;}{if(p->packet_length < 1) {\n$1    return LIBSSH2_ERROR_DECRYPT;\n$1}\n$1else if(p->packet_length > LIBSSH2_PACKET_MAXPAYLOAD) {\n$1    return LIBSSH2_ERROR_OUT_OF_BOUNDARY;\n$1}}g' "$TP"
    PC=$(grep -c "packet_length > LIBSSH2_PACKET_MAXPAYLOAD" "$TP")
    [ "$PC" -ge 2 ] || die "CVE-2026-55200 patch verification failed (MAXPAYLOAD upper-bound checks=$PC; expected >=2)"
    ok "Applied CVE-2026-55200 patch (added upper-bound checks in transport.c; $PC MAXPAYLOAD boundary returns)"
elif [ "$VULN" = "0" ] && grep -q "packet_length > LIBSSH2_PACKET_MAXPAYLOAD" "$TP"; then
    warn "No vulnerable branch found and upper-bound checks already exist; assuming a fixed version and skipping the patch"
else
    die "CVE-2026-55200: target code does not match (vulnerable branches=$VULN); the libssh2 version may have changed; review transport.c manually"
fi

# Static arm64 CMake configuration with OpenSSL backend.
section "Configure CMake (static / OpenSSL backend)"
step "cmake configure…"
rm -rf "$BUILD" "$STAGE"
# Key options:
# BUILD_SHARED_LIBS=OFF creates static libraries.
# CRYPTO_BACKEND=OpenSSL reuses the same static crypto backend.
# OPENSSL_USE_STATIC_LIBS=ON configures linkage without merging OpenSSL into the output; see header notes.
# ENABLE_ZLIB_COMPRESSION=ON uses system zlib, already linked by the app.
# Disable LTO to avoid bitcode causing create-xcframework Unknown header errors, matching FreeRDP.
run_quiet cmake -S "$SRC" -B "$BUILD" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF \
    -DCMAKE_C_FLAGS="-fno-lto" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOY" \
    -DCMAKE_INSTALL_PREFIX="$STAGE" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DBUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF \
    -DLIBSSH2_NO_DEPRECATED=ON \
    -DENABLE_ZLIB_COMPRESSION=ON \
    -DCRYPTO_BACKEND=OpenSSL \
    -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
    -DOPENSSL_USE_STATIC_LIBS=ON \
    || die "CMake configuration failed (see ${LOG}); check CRYPTO_BACKEND/OPENSSL_ROOT_DIR or option names that may have changed between versions."
ok "Configuration complete"

# Compile and install.
section "Build"
step "cmake --build (parallel)..."
run_quiet cmake --build "$BUILD" --parallel "$(sysctl -n hw.ncpu)"
run_quiet cmake --install "$BUILD"
LIBA="$(find "$STAGE" -name 'libssh2.a' | head -1)"
[ -n "$LIBA" ] || die "No libssh2.a found in $STAGE (check whether the build produced a static library)"
ok "Build complete -> ${LIBA#$ROOT/}"

# Assemble xcframework with libssh2.a/headers only, excluding OpenSSL.
section "Assemble xcframework"
step "Collect headers..."
HDR="$WORK/headers"; rm -rf "$HDR"; mkdir -p "$HDR"
cp -R "$STAGE/include/." "$HDR/"   # libssh2.h / libssh2_sftp.h / libssh2_publickey.h
step "xcodebuild -create-xcframework…"
rm -rf "$OUT"; mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework \
    -library "$LIBA" -headers "$HDR" \
    -output "$OUT" >>"$LOG" 2>&1 || die "create-xcframework failed (see ${LOG})"
ok "xcframework → ${OUT#$ROOT/}"

# Verify output.
section "Verify"
LIBIN="$(find "$OUT" -name '*.a' | head -1)"
info "Architecture: $(lipo -archs "$LIBIN" 2>/dev/null)"
info "libssh2_init symbols: $(nm "$LIBIN" 2>/dev/null | grep -c 'libssh2_init' || echo 0)(expected >=1)"
info "Undefined OpenSSL references (expected; resolved by CFreeRDP when linking the app): $(nm -u "$LIBIN" 2>/dev/null | grep -c 'EVP_\|SSL_' || echo 0)"
printf '%s✓ Done%s  Output: %s\n' "$BOLD$GRN" "$RST" "${OUT#$ROOT/}"
