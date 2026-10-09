// SMAA (Enhanced Subpixel Morphological Antialiasing), blend pass, vert stage.
// Generated from SMAA.hlsl (https://github.com/iryoku/smaa, MIT licence, Copyright (C) 2013
// Jorge Jimenez, Jose I. Echevarria, Belen Masia, Fernando Navarro, Diego Gutierrez) and the
// GLSL entry points in visionos/scripts/smaa/ through glslang and SPIRV-Cross
// (visionos/scripts/smaa/generate.sh). Do not edit: generate it again.

#pragma clang diagnostic ignored "-Wmissing-prototypes"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct SMAAParams
{
    float4 rt_metrics;
};

struct smaaBlendVertex_out
{
    float2 v_uv [[user(locn0)]];
    float4 v_offset [[user(locn1)]];
    float4 gl_Position [[position]];
};

static inline __attribute__((always_inline))
void SMAANeighborhoodBlendingVS(thread const float2& texcoord, thread float4& offset, constant SMAAParams& _18)
{
    offset = fma(_18.rt_metrics.xyxy, float4(1.0, 0.0, 0.0, 1.0), texcoord.xyxy);
}

vertex smaaBlendVertex_out smaaBlendVertex(constant SMAAParams& _18 [[buffer(0)]], uint gl_VertexIndex [[vertex_id]])
{
    smaaBlendVertex_out out = {};
    float2 ndc = float2((int(gl_VertexIndex) == 1) ? 3.0 : (-1.0), (int(gl_VertexIndex) == 2) ? 3.0 : (-1.0));
    out.gl_Position = float4(ndc, 0.0, 1.0);
    out.v_uv = float2((ndc.x * 0.5) + 0.5, 0.5 - (ndc.y * 0.5));
    float2 param = out.v_uv;
    float4 param_1;
    SMAANeighborhoodBlendingVS(param, param_1, _18);
    float4 offset = param_1;
    out.v_offset = offset;
    return out;
}

