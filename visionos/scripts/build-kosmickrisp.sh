#!/usr/bin/env bash
# KosmicKrisp (Mesa's Vulkan driver on Metal, the one shadPS4's macOS build uses) for visionOS,
# as a framework the app carries and the emulator loads at start (vk_platform.cpp). Unlike
# MoltenVK it has geometry and tessellation shaders, which it runs as compute work before the
# draw (as Asahi's driver does on Apple GPUs).
#
# Mesa is the commit shadPS4's externals/mesa-kosmickrisp pins, with
# visionos/patches/kosmickrisp-visionos.patch:
#   - the Metal device is the system's (MTLCopyAllDevices is macOS only);
#   - vm_* calls where macOS has mach_vm_* (no mach_vm.h for iOS and visionOS apps);
#   - VK_EXT_metal_objects for images, which the headset's frames are handed over with;
#   - -Dkosmickrisp-embedded: frameworks linked directly and an @rpath install name.
#
# Needs (Homebrew): meson pkg-config llvm spirv-tools spirv-llvm-translator libclc, and Python's mako,
# packaging and pyyaml; Xcode with the visionOS SDK. Mesa's build tools (mesa_clc and the
# others that compile its OpenCL C into shaders) are built for this Mac first.
#
# Output: build/visionos/kosmickrisp/KosmicKrisp.framework
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MESA_URL="${KOSMICKRISP_MESA_URL:-https://github.com/shadexternals/mesa.git}"
MESA_COMMIT="${KOSMICKRISP_MESA_COMMIT:-b628375fb1fd99476bfbaaa0532deb6fe3a6870e}"
PATCH="$ROOT/visionos/patches/kosmickrisp-visionos.patch"
DEPLOYMENT_TARGET="${VISIONOS_DEPLOYMENT_TARGET:-26.0}"
OUT="$ROOT/build/visionos/kosmickrisp"
WORK="$ROOT/build/visionos/kosmickrisp-src"
FRAMEWORK="$OUT/KosmicKrisp.framework"

STAMP="$MESA_COMMIT $(shasum "$PATCH" | cut -d' ' -f1) $DEPLOYMENT_TARGET"
if [[ -f "$FRAMEWORK/KosmicKrisp" && -f "$OUT/STAMP" && "$(cat "$OUT/STAMP")" == "$STAMP" ]]; then
  echo "KosmicKrisp for visionOS is already built ($STAMP)"
  exit 0
fi

# --- the sources --------------------------------------------------------------------------------
mkdir -p "$WORK"
MESA="$WORK/mesa"
if [[ ! -d "$MESA/.git" ]]; then
  git init -q "$MESA"
  git -C "$MESA" remote add origin "$MESA_URL"
fi
git -C "$MESA" fetch -q --depth 1 origin "$MESA_COMMIT"
git -C "$MESA" checkout -q -f FETCH_HEAD
git -C "$MESA" clean -qfdx -e build-tools -e build-xros
git -C "$MESA" apply --whitespace=nowarn "$PATCH"
echo "Mesa $MESA_COMMIT with $(basename "$PATCH")"

COMMON=(-Dplatforms=macos -Dvulkan-drivers=kosmickrisp -Dgallium-drivers= -Dopengl=false
        -Dzstd=disabled)

# --- Mesa's build tools, for this Mac -----------------------------------------------------------
BREW=$(brew --prefix)
export LLVM_CONFIG="${LLVM_CONFIG:-$BREW/opt/llvm/bin/llvm-config}"
export PATH="$BREW/opt/llvm/bin:$PATH"
TOOLS="$MESA/build-tools"
if [[ ! -f "$TOOLS/build.ninja" ]]; then
  (cd "$MESA" && meson setup "$TOOLS" --buildtype=release \
     -Dinstall-mesa-clc=true -Dinstall-precomp-compiler=true "${COMMON[@]}")
fi
meson compile -C "$TOOLS" mesa_clc vtn_bindgen2 kk_clc

# --- the driver, for visionOS -------------------------------------------------------------------
SDK=$(xcrun --sdk xros --show-sdk-path)
CC=$(xcrun --sdk xros --find clang)
CXX=$(xcrun --sdk xros --find clang++)
TARGET="arm64-apple-xros$DEPLOYMENT_TARGET"
FLAGS="'-target', '$TARGET', '-isysroot', '$SDK'"
CROSS="$WORK/xros.ini"
cat > "$CROSS" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
objc = '$CC'
objcpp = '$CXX'
ar = '$(xcrun --sdk xros --find ar)'
strip = '$(xcrun --sdk xros --find strip)'

[built-in options]
c_args = [$FLAGS]
cpp_args = [$FLAGS]
objc_args = [$FLAGS]
objcpp_args = [$FLAGS]
c_link_args = [$FLAGS]
cpp_link_args = [$FLAGS]
objc_link_args = [$FLAGS]
objcpp_link_args = [$FLAGS]

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

XROS="$MESA/build-xros"
export PATH="$TOOLS/src/compiler/clc:$TOOLS/src/compiler/spirv:$TOOLS/src/kosmickrisp/clc:$PATH"
if [[ ! -f "$XROS/build.ninja" ]]; then
  (cd "$MESA" && meson setup "$XROS" --cross-file "$CROSS" --buildtype=release --prefer-static \
     -Dmesa-clc=system -Dprecomp-compiler=system -Dspirv-tools=disabled -Dllvm=disabled \
     -Dxmlconfig=disabled -Dexpat=disabled -Dkosmickrisp-embedded=true "${COMMON[@]}")
fi
meson compile -C "$XROS" vulkan_kosmickrisp

LIBRARY="$XROS/src/kosmickrisp/vulkan/libvulkan_kosmickrisp.dylib"
[[ -f "$LIBRARY" ]] || { echo "No $LIBRARY"; exit 1; }

# --- the framework ------------------------------------------------------------------------------
rm -rf "$FRAMEWORK"
mkdir -p "$FRAMEWORK"
cp "$LIBRARY" "$FRAMEWORK/KosmicKrisp"
install_name_tool -id @rpath/KosmicKrisp.framework/KosmicKrisp "$FRAMEWORK/KosmicKrisp"
cat > "$FRAMEWORK/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>KosmicKrisp</string>
  <key>CFBundleIdentifier</key><string>org.mesa3d.kosmickrisp</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>KosmicKrisp</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>XROS</string></array>
  <key>MinimumOSVersion</key><string>$DEPLOYMENT_TARGET</string>
</dict>
</plist>
EOF
plutil -convert binary1 "$FRAMEWORK/Info.plist"

echo "What KosmicKrisp needs from the system:"
otool -L "$FRAMEWORK/KosmicKrisp"
echo "Its entry points:"
nm -gU "$FRAMEWORK/KosmicKrisp" | grep -E 'vk_icd|vkGetInstanceProcAddr' || true
echo "$STAMP" > "$OUT/STAMP"
ls -la "$FRAMEWORK"
