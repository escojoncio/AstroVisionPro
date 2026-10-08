#!/usr/bin/env bash
# MoltenVK (Vulkan on Metal) for visionOS, as the static library the app links: the emulator draws
# with Vulkan, and on Apple Vision Pro only Metal exists. The app also carries KosmicKrisp
# (build-kosmickrisp.sh), which has geometry shaders; MoltenVK is the driver when that one is
# missing or vulkan_driver=moltenvk is set.
#
# Output: build/visionos/moltenvk/libMoltenVK.a
# The release's prebuilt package is used when it has visionOS in it; otherwise MoltenVK is built.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
VERSION="${MOLTENVK_VERSION:-v1.4.2}"
OUT="$ROOT/build/visionos/moltenvk"
WORK="$ROOT/build/visionos/moltenvk-src"

if [[ -f "$OUT/libMoltenVK.a" && -f "$OUT/VERSION" && $(cat "$OUT/VERSION") == "$VERSION" ]]; then
  echo "MoltenVK $VERSION for visionOS is already built"
  exit 0
fi
mkdir -p "$OUT"
rm -f "$OUT/libMoltenVK.a"

# The device slice of a static MoltenVK.xcframework (not the simulator's).
device_library() {
  find "$1" -path '*MoltenVK.xcframework/xros-arm64/*' -name 'libMoltenVK.a' -not -path '*simulator*' 2>/dev/null | head -n 1
}

# 1. The release's package.
PACKAGE=$(mktemp -d)
if curl -fsSL -o "$PACKAGE/MoltenVK-all.tar" \
     "https://github.com/KhronosGroup/MoltenVK/releases/download/$VERSION/MoltenVK-all.tar"; then
  tar -xf "$PACKAGE/MoltenVK-all.tar" -C "$PACKAGE"
  LIBRARY=$(device_library "$PACKAGE")
  if [[ -n "$LIBRARY" ]]; then
    cp "$LIBRARY" "$OUT/libMoltenVK.a"
    echo "MoltenVK $VERSION for visionOS: from the release package ($LIBRARY)"
  fi
fi
rm -rf "$PACKAGE"

# 2. Built from source.
if [[ ! -f "$OUT/libMoltenVK.a" ]]; then
  echo "MoltenVK $VERSION: no visionOS library in the release package, building it"
  if [[ ! -d "$WORK/.git" ]] || [[ $(git -C "$WORK" describe --tags 2>/dev/null) != "$VERSION" ]]; then
    rm -rf "$WORK"
    git clone -q --depth 1 --branch "$VERSION" https://github.com/KhronosGroup/MoltenVK.git "$WORK"
  fi
  (
    cd "$WORK"
    ./fetchDependencies --visionos --parallel-build
    make visionos
  )
  LIBRARY=$(device_library "$WORK/Package")
  if [[ -z "$LIBRARY" ]]; then
    echo "MoltenVK was built, but its visionOS library was not found" >&2
    find "$WORK/Package" -name '*.a' >&2 || true
    exit 1
  fi
  cp "$LIBRARY" "$OUT/libMoltenVK.a"
fi

echo "$VERSION" > "$OUT/VERSION"
lipo -info "$OUT/libMoltenVK.a" || true
