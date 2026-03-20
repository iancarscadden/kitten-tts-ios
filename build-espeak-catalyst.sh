#!/bin/bash
# build-espeak-catalyst.sh
# Builds libespeak-ng, libspeechPlayer, and libucd for both iOS arm64 and
# Mac Catalyst (arm64-apple-ios-macabi), then places the outputs in:
#   localChat/espeak-lib/ios/       ← linked when sdk=iphoneos* / iphonesimulator*
#   localChat/espeak-lib/catalyst/  ← linked when sdk=macosx*
#
# Requirements: Xcode 16+, CMake 3.21+, autoconf, automake, libtool (brew)
#   brew install cmake autoconf automake libtool

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.espeak-build"
OUTPUT_ROOT="$SCRIPT_DIR/localChat/espeak-lib"
IOS_OUT="$OUTPUT_ROOT/platform-iphoneos"
SIMULATOR_OUT="$OUTPUT_ROOT/platform-iphonesimulator"
CATALYST_OUT="$OUTPUT_ROOT/platform-maccatalyst"

ESPEAK_TAG="1.52.0"
ESPEAK_REPO="https://github.com/espeak-ng/espeak-ng.git"
IOS_DEPLOYMENT_TARGET="26.0"

IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"

echo "==> Using iOS SDK:   $IOS_SDK"
echo "==> Using macOS SDK: $MACOS_SDK"
echo "==> iOS deployment target: $IOS_DEPLOYMENT_TARGET"

# ── Endian compatibility shim (le16toh/le32toh are Linux-only) ───────────────
ENDIAN_COMPAT="$BUILD_DIR/endian-compat.h"
mkdir -p "$BUILD_DIR"
cat > "$ENDIAN_COMPAT" << 'EOF'
#pragma once
#if defined(__APPLE__)
#include <machine/endian.h>
#include <libkern/OSByteOrder.h>
#define le16toh(x) OSSwapLittleToHostInt16(x)
#define le32toh(x) OSSwapLittleToHostInt32(x)
#define le64toh(x) OSSwapLittleToHostInt64(x)
#define htole16(x) OSSwapHostToLittleInt16(x)
#define htole32(x) OSSwapHostToLittleInt32(x)
#define htole64(x) OSSwapHostToLittleInt64(x)
#define be16toh(x) OSSwapBigToHostInt16(x)
#define be32toh(x) OSSwapBigToHostInt32(x)
#define be64toh(x) OSSwapBigToHostInt64(x)
#endif
EOF
echo "==> Wrote endian-compat.h shim"

# ── Clone / update espeak-ng ──────────────────────────────────────────────────
SRC_DIR="$BUILD_DIR/espeak-ng-src"
if [ ! -d "$SRC_DIR/.git" ]; then
    echo "==> Cloning espeak-ng $ESPEAK_TAG …"
    mkdir -p "$BUILD_DIR"
    git clone --depth 1 --branch "$ESPEAK_TAG" "$ESPEAK_REPO" "$SRC_DIR"
else
    echo "==> espeak-ng source already present, skipping clone"
fi

# ── Helper: build one slice ───────────────────────────────────────────────────
build_slice() {
    local SLICE_NAME="$1"   # "ios" or "catalyst"
    local C_TARGET="$2"     # clang -target triple
    local CXX_TARGET="$3"
    local SDK="$4"
    local OUT_DIR="$5"

    local BUILD_SUBDIR="$BUILD_DIR/build-$SLICE_NAME"
    rm -rf "$BUILD_SUBDIR"
    mkdir -p "$BUILD_SUBDIR"

    echo ""
    echo "==> Building slice: $SLICE_NAME  (target=$C_TARGET)"

    cmake -S "$SRC_DIR" -B "$BUILD_SUBDIR" \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DESPEAK_NG_BUILD_TESTS=OFF \
        -DESPEAK_NG_BUILD_DOCUMENTATION=OFF \
        -DUSE_SPEECHPLAYER=ON \
        -DCMAKE_OSX_SYSROOT="$SDK" \
        -DCMAKE_OSX_ARCHITECTURES="arm64" \
        -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
        -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
        -DCMAKE_C_FLAGS="-target $C_TARGET -include $ENDIAN_COMPAT" \
        -DCMAKE_CXX_FLAGS="-target $CXX_TARGET -include $ENDIAN_COMPAT" \
        -DCMAKE_EXE_LINKER_FLAGS="-target $C_TARGET" \
        -DCMAKE_MODULE_LINKER_FLAGS="-target $C_TARGET" \
        -DCMAKE_SHARED_LINKER_FLAGS="-target $C_TARGET"

    # Build only the static library targets — skip data compilation which
    # tries to execute the cross-compiled binary on the host machine.
    cmake --build "$BUILD_SUBDIR" --config Release -j"$(sysctl -n hw.logicalcpu)" \
        --target espeak-ng --target ucd --target speechPlayer

    mkdir -p "$OUT_DIR"

    # Collect all static libs produced by the build
    find "$BUILD_SUBDIR" -name "*.a" | while read -r lib; do
        local libname
        libname="$(basename "$lib")"
        cp "$lib" "$OUT_DIR/$libname"
        echo "    [copy] $libname → $OUT_DIR"
    done

    echo "==> Slice $SLICE_NAME done."
}

# ── Build iOS device slice ────────────────────────────────────────────────────
build_slice \
    "ios" \
    "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" \
    "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}" \
    "$IOS_SDK" \
    "$IOS_OUT"

# ── Copy iOS slice for simulator (same arm64 libs) ────────────────────────────
rm -rf "$SIMULATOR_OUT"
cp -R "$IOS_OUT" "$SIMULATOR_OUT"
echo "==> Copied iOS slice → simulator slice"

# ── Build Mac Catalyst slice ──────────────────────────────────────────────────
build_slice \
    "catalyst" \
    "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-macabi" \
    "arm64-apple-ios${IOS_DEPLOYMENT_TARGET}-macabi" \
    "$MACOS_SDK" \
    "$CATALYST_OUT"

# ── Verify outputs ────────────────────────────────────────────────────────────
echo ""
echo "==> Output libraries:"
echo "    iOS (platform-iphoneos):"
ls -lh "$IOS_OUT"/*.a 2>/dev/null | awk '{print "      "$NF" ("$5")"}'
echo "    Catalyst (platform-maccatalyst):"
ls -lh "$CATALYST_OUT"/*.a 2>/dev/null | awk '{print "      "$NF" ("$5")"}'

# ── Sanity check: verify the catalyst libs are actually Catalyst-targeted ─────
echo ""
echo "==> Verifying Catalyst libs are not plain iOS (checking load commands)…"
for lib in "$CATALYST_OUT"/*.a; do
    # Extract one .o and check its platform
    local_tmp="$(mktemp -d)"
    (cd "$local_tmp" && ar -x "$lib" 2>/dev/null; true)
    first_o="$(find "$local_tmp" -name "*.o" | head -1)"
    if [ -n "$first_o" ]; then
        platform="$(xcrun vtool -show-build "$first_o" 2>/dev/null | grep platform || echo "  (could not read)")"
        echo "    $(basename "$lib"): $platform"
    fi
    rm -rf "$local_tmp"
done

echo ""
echo "✅  Build complete."
echo ""
echo "Next steps:"
echo "  1. In Xcode, open KittenSpeech.xcodeproj"
echo "  2. Build Settings → SUPPORTS_MACCATALYST = YES  (already done if you ran update-project.sh)"
echo "  3. Build for 'My Mac (Designed for iPad)' — it should now link the catalyst/ libs."
