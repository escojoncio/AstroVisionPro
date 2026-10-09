#version 450
#extension GL_GOOGLE_include_directive : require
#include "common.glsl"
#define SMAA_INCLUDE_PS 0
#include "SMAA.hlsl"
layout(location = 0) out vec2 v_uv;
layout(location = 1) out vec4 v_offset0;
layout(location = 2) out vec4 v_offset1;
layout(location = 3) out vec4 v_offset2;
void main() {
    vec2 ndc = vec2(gl_VertexIndex == 1 ? 3.0 : -1.0, gl_VertexIndex == 2 ? 3.0 : -1.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    v_uv = vec2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    vec4 offset[3];
    SMAAEdgeDetectionVS(v_uv, offset);
    v_offset0 = offset[0]; v_offset1 = offset[1]; v_offset2 = offset[2];
}
