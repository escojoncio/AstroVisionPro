#version 450
#extension GL_GOOGLE_include_directive : require
#include "common.glsl"
#define SMAA_INCLUDE_VS 0
#include "SMAA.hlsl"
layout(binding = 1) uniform sampler2D edgesTex;
layout(binding = 2) uniform sampler2D areaTex;
layout(binding = 3) uniform sampler2D searchTex;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec2 v_pixcoord;
layout(location = 2) in vec4 v_offset0;
layout(location = 3) in vec4 v_offset1;
layout(location = 4) in vec4 v_offset2;
layout(location = 0) out vec4 o_weights;
void main() {
    vec4 offset[3];
    offset[0] = v_offset0; offset[1] = v_offset1; offset[2] = v_offset2;
    o_weights = SMAABlendingWeightCalculationPS(v_uv, v_pixcoord, offset, edgesTex, areaTex,
                                                searchTex, vec4(0.0));
}
