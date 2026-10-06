#!/usr/bin/env bash
# The emulator (shadPS4 with FEXCore, as the Quest and PC builds have it) for visionOS, as one
# static archive the app links: visionos/build/core/libastroquest_core.a, with MoltenVK next to
# it (visionos/build/core/libMoltenVK.a).
#
# Needs: the submodules of shadps4-arm64-main/externals the build uses, Xcode with the visionOS
# SDK, cmake and ninja. Runs build-fexcore.sh and build-moltenvk.sh first when their output is
# missing.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORE="$ROOT/shadps4-arm64-main"
BUILD="${CORE_BUILD_DIR:-$ROOT/build/visionos/core}"
OUT="$ROOT/visionos/build/core"
DEPLOYMENT_TARGET="${VISIONOS_DEPLOYMENT_TARGET:-26.0}"
FEX_SRC="$ROOT/build/visionos/fex-src"
FEX_BUILD="$ROOT/build/visionos/fexcore"

[[ -f "$FEX_BUILD/FEXCore/Source/libFEXCore.a" ]] || bash "$ROOT/visionos/scripts/build-fexcore.sh"
bash "$ROOT/visionos/scripts/build-moltenvk.sh"

# Dear ImGui's font embedder runs while building, so it is built for this Mac.
HOST_TOOLS="$ROOT/build/visionos/host-tools"
mkdir -p "$HOST_TOOLS"
if [[ ! -x "$HOST_TOOLS/binary_to_compressed_c" ]]; then
  xcrun --sdk macosx clang++ -O2 -std=c++17 \
    "$CORE/externals/dear_imgui/misc/fonts/binary_to_compressed_c.cpp" \
    -o "$HOST_TOOLS/binary_to_compressed_c"
fi

LAUNCHER=()
command -v ccache >/dev/null && LAUNCHER=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache -DCMAKE_OBJC_COMPILER_LAUNCHER=ccache -DCMAKE_OBJCXX_COMPILER_LAUNCHER=ccache)

cmake -S "$CORE" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT=xros \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
  -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_FEX_GUEST_CPU=ON \
  -DENABLE_SYSTEM_VULKAN=ON \
  -DENABLE_DISCORD_RPC=OFF \
  -DENABLE_UPDATER=OFF \
  -DENABLE_TESTS=OFF \
  -DFEXCORE_GUEST_CPU_SOURCE_DIR="$FEX_SRC" \
  -DFEXCORE_GUEST_CPU_BUILD_DIR="$FEX_BUILD" \
  -DIMGUI_FONT_EMBED_EXECUTABLE="$HOST_TOOLS/binary_to_compressed_c" \
  -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST_LIBRARY=OFF \
  -DLIBUSB_BUILD_SHARED_LIBS=OFF \
  "${LAUNCHER[@]}"

cmake --build "$BUILD" --target shadps4 --parallel -- -k 0

# One archive: the emulator, the libraries it was built with, and FEXCore.
mkdir -p "$OUT"
LIBS=("$BUILD/libshadps4.a")
while IFS= read -r LIB; do
  case "$(basename "$LIB")" in
    libshadps4.a|libusb-1.0.a|libhwinfo*.a) continue ;;
  esac
  LIBS+=("$LIB")
done < <(find "$BUILD" -name '*.a' -not -path '*/CMakeFiles/*' | sort)
while IFS= read -r LIB; do
  LIBS+=("$LIB")
done < <(find "$FEX_BUILD" -name '*.a' -not -path '*/CMakeFiles/*' -not -name 'librpmalloc.a' | sort)

printf 'Into libastroquest_core.a:\n'; printf '  %s\n' "${LIBS[@]}"
rm -f "$OUT/libastroquest_core.a"
xcrun libtool -static -no_warning_for_no_symbols -o "$OUT/libastroquest_core.a" "${LIBS[@]}"
cp "$ROOT/build/visionos/moltenvk/libMoltenVK.a" "$OUT/libMoltenVK.a"
ls -la "$OUT"
