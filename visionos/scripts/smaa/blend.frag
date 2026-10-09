#version 450
#extension GL_GOOGLE_include_directive : require
#include "common.glsl"
#define SMAA_INCLUDE_VS 0
#include "SMAA.hlsl"
layout(binding = 1) uniform sampler2D colorTex;
layout(binding = 2) uniform sampler2D blendTex;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_offset;
layout(location = 0) out vec4 o_color;
void main() {
    o_color = SMAANeighborhoodBlendingPS(v_uv, v_offset, colorTex, blendTex);
}
