// SMAA (Enhanced Subpixel Morphological Antialiasing), edge pass, frag stage.
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

struct smaaEdgeFragment_out
{
    float2 o_edges [[color(0)]];
};

struct smaaEdgeFragment_in
{
    float2 v_uv [[user(locn0)]];
    float4 v_offset0 [[user(locn1)]];
    float4 v_offset1 [[user(locn2)]];
    float4 v_offset2 [[user(locn3)]];
};

static inline __attribute__((always_inline))
float LumaAt(thread const float2& uv, texture2d<float> colorTex, sampler colorTexSmplr)
{
    return dot(sqrt(fast::max(colorTex.sample(colorTexSmplr, uv, level(0.0)).xyz, float3(0.0))), float3(0.2125999927520751953125, 0.715200006961822509765625, 0.072200000286102294921875));
}

fragment smaaEdgeFragment_out smaaEdgeFragment(smaaEdgeFragment_in in [[stage_in]], constant SMAAParams& _83 [[buffer(0)]], texture2d<float> colorTex [[texture(1)]], sampler colorTexSmplr [[sampler(1)]])
{
    smaaEdgeFragment_out out = {};
    float2 threshold = float2(0.100000001490116119384765625);
    float2 param = in.v_uv;
    float L = LumaAt(param, colorTex, colorTexSmplr);
    float2 param_1 = in.v_offset0.xy;
    float Lleft = LumaAt(param_1, colorTex, colorTexSmplr);
    float2 param_2 = in.v_offset0.zw;
    float Ltop = LumaAt(param_2, colorTex, colorTexSmplr);
    float2 _64 = abs(float2(L) - float2(Lleft, Ltop));
    float4 delta;
    delta.x = _64.x;
    delta.y = _64.y;
    float2 edges = step(threshold, delta.xy);
    float column = floor(in.v_uv.x * _83.rt_metrics.z);
    if (column == floor(_83.rt_metrics.z * 0.5))
    {
        edges.x = 0.0;
    }
    if (dot(edges, float2(1.0)) == 0.0)
    {
        discard_fragment();
    }
    float2 param_3 = in.v_offset1.xy;
    float Lright = LumaAt(param_3, colorTex, colorTexSmplr);
    float2 param_4 = in.v_offset1.zw;
    float Lbottom = LumaAt(param_4, colorTex, colorTexSmplr);
    float2 _128 = abs(float2(L) - float2(Lright, Lbottom));
    delta.z = _128.x;
    delta.w = _128.y;
    float2 maxDelta = fast::max(delta.xy, delta.zw);
    float2 param_5 = in.v_offset2.xy;
    float Lleftleft = LumaAt(param_5, colorTex, colorTexSmplr);
    float2 param_6 = in.v_offset2.zw;
    float Ltoptop = LumaAt(param_6, colorTex, colorTexSmplr);
    float2 _158 = abs(float2(Lleft, Ltop) - float2(Lleftleft, Ltoptop));
    delta.z = _158.x;
    delta.w = _158.y;
    maxDelta = fast::max(maxDelta, delta.zw);
    float finalDelta = fast::max(maxDelta.x, maxDelta.y);
    edges *= step(float2(finalDelta), delta.xy * 2.0);
    out.o_edges = edges;
    return out;
}

