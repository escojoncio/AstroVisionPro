#!/bin/sh
# Makes visionos/App/Render/SMAA/SMAA_*.metal from SMAA.hlsl and the GLSL entry points here:
#   SMAA_HLSL=<path to iryoku/smaa SMAA.hlsl> GLSLANG=<glslang> SPIRV_CROSS=<spirv-cross> ./generate.sh
# The area and search textures (AreaTex.bin 160x560 RG8, SearchTex.bin 64x16 R8) are the bytes of
# iryoku/smaa Textures/AreaTex.h and SearchTex.h.
set -e
cd "$(dirname "$0")"
cp "$SMAA_HLSL" SMAA.hlsl
out=../../App/Render/SMAA
for s in edge weight blend; do
  cap=$(echo "$s" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')
  for st in vert frag; do
    "$GLSLANG" -V --target-env vulkan1.1 "$s.$st" -o "$s.$st.spv"
    case $st in vert) kind=Vertex;; frag) kind=Fragment;; esac
    "$SPIRV_CROSS" "$s.$st.spv" --msl --msl-version 20300 --msl-decoration-binding \
      --rename-entry-point main "smaa$cap$kind" "$st" --output "$s.$st.metal"
    rm "$s.$st.spv"
  done
done
echo "Now put the licence header on each and move them to $out."
