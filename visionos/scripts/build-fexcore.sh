#!/usr/bin/env bash
# Builds FEXCore (the x86-64 to ARM64 translator the emulator runs the game's code with) for
# visionOS, from the revision the Quest build uses (shadps4-arm64-main/runtime/locks), with the
# Quest build's FEXCore-only patch and this port's Apple patch (visionos/patches/fex-darwin.patch).
#
# Output: build/visionos/fexcore (the static libraries the emulator links, in the places
# shadps4-arm64-main/CMakeLists.txt expects them) and build/visionos/fex-src (the source).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CORE="$ROOT/shadps4-arm64-main"
LOCK="$CORE/runtime/locks/components.lock.json"
SRC="${FEX_SOURCE_DIR:-$ROOT/build/visionos/fex-src}"
BUILD="${FEX_BUILD_DIR:-$ROOT/build/visionos/fexcore}"
DEPLOYMENT_TARGET="${VISIONOS_DEPLOYMENT_TARGET:-26.0}"

read -r FEX_URL FEX_REVISION < <(python3 - "$LOCK" <<'EOF'
import json, sys
lock = json.load(open(sys.argv[1]))
fex = next(c for c in lock["components"] if c["name"] == "fex")
print(fex["url"], fex["revision"])
EOF
)

if [[ ! -d "$SRC/.git" ]] || [[ $(git -C "$SRC" rev-parse HEAD 2>/dev/null) != "$FEX_REVISION" ]]; then
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$FEX_URL"
  git -C "$SRC" fetch -q --depth 1 origin "$FEX_REVISION"
  git -C "$SRC" checkout -q FETCH_HEAD
fi
git -C "$SRC" submodule update --init --depth 1 --jobs 8 -- \
  External/unordered_dense External/rpmalloc External/xxhash External/fmt External/range-v3 \
  Source/Common/cpp-optparse

# The patches, on a clean tree each time.
git -C "$SRC" checkout -q -- .
git -C "$SRC" clean -qfd -e build
git -C "$SRC" apply "$CORE/runtime/patches/fex-fexcore-only.patch"
git -C "$SRC" apply "$ROOT/visionos/patches/fex-darwin.patch"

cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=visionOS \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
  -DCMAKE_C_COMPILER="$(xcrun --find clang)" \
  -DCMAKE_CXX_COMPILER="$(xcrun --find clang++)" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DTUNE_CPU=none \
  -DBUILD_FEXCORE_ONLY=ON \
  -DFEXCORE_SMOKE_SOURCE="$CORE/runtime/probes/fexcore-smoke.cpp" \
  -DBUILD_TESTING=OFF \
  -DBUILD_FEX_LINUX_TESTS=OFF \
  -DBUILD_THUNKS=OFF \
  -DBUILD_FEXCONFIG=OFF \
  -DENABLE_GDB_SYMBOLS=OFF \
  -DENABLE_LTO=OFF \
  -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
  -DENABLE_FEX_ALLOCATOR=OFF \
  -DENABLE_OFFLINE_TELEMETRY=OFF \
  -DENABLE_VIXL_DISASSEMBLER=OFF \
  -DENABLE_VIXL_SIMULATOR=OFF \
  -DENABLE_ZYDIS=OFF \
  -DENABLE_FEXCORE_PROFILER=OFF \
  -DENABLE_CCACHE=ON

cmake --build "$BUILD" --parallel -- -k 0 FEXCore FEXCore_Base Common CommonTools JemallocLibs

echo "FEXCore for visionOS:"
find "$BUILD" -name '*.a' -print
