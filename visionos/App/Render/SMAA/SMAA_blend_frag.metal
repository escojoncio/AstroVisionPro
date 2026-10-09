// SMAA (Enhanced Subpixel Morphological Antialiasing), blend pass, frag stage.
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

struct smaaBlendFragment_out
{
    float4 o_color [[color(0)]];
};

struct smaaBlendFragment_in
{
    float2 v_uv [[user(locn0)]];
    float4 v_offset [[user(locn1)]];
};

static inline __attribute__((always_inline))
void SMAAMovc(thread const bool2& cond, thread float2& variable, thread const float2& value)
{
    if (cond.x)
    {
        variable.x = value.x;
    }
    if (cond.y)
    {
        variable.y = value.y;
    }
}

static inline __attribute__((always_inline))
void SMAAMovc(thread const bool4& cond, thread float4& variable, thread const float4& value)
{
    bool2 param = cond.xy;
    float2 param_1 = variable.xy;
    float2 param_2 = value.xy;
    SMAAMovc(param, param_1, param_2);
    variable.x = param_1.x;
    variable.y = param_1.y;
    bool2 param_3 = cond.zw;
    float2 param_4 = variable.zw;
    float2 param_5 = value.zw;
    SMAAMovc(param_3, param_4, param_5);
    variable.z = param_4.x;
    variable.w = param_4.y;
}

static inline __attribute__((always_inline))
float4 SMAANeighborhoodBlendingPS(thread const float2& texcoord, thread const float4& offset, texture2d<float> colorTex, sampler colorTexSmplr, texture2d<float> blendTex, sampler blendTexSmplr, constant SMAAParams& _180)
{
    float4 a;
    a.x = blendTex.sample(blendTexSmplr, offset.xy).w;
    a.y = blendTex.sample(blendTexSmplr, offset.zw).y;
    float2 _105 = blendTex.sample(blendTexSmplr, texcoord).xz;
    a.w = _105.x;
    a.z = _105.y;
    if (dot(a, float4(1.0)) < 9.9999997473787516355514526367188e-06)
    {
        float4 color = colorTex.sample(colorTexSmplr, texcoord, level(0.0));
        return color;
    }
    else
    {
        bool h = fast::max(a.x, a.z) > fast::max(a.y, a.w);
        float4 blendingOffset = float4(0.0, a.y, 0.0, a.w);
        float2 blendingWeight = a.yw;
        bool4 param = bool4(h);
        float4 param_1 = blendingOffset;
        float4 param_2 = float4(a.x, 0.0, a.z, 0.0);
        SMAAMovc(param, param_1, param_2);
        blendingOffset = param_1;
        bool2 param_3 = bool2(h);
        float2 param_4 = blendingWeight;
        float2 param_5 = a.xz;
        SMAAMovc(param_3, param_4, param_5);
        blendingWeight = param_4;
        blendingWeight /= float2(dot(blendingWeight, float2(1.0)));
        float4 blendingCoord = fma(blendingOffset, float4(_180.rt_metrics.xy, -_180.rt_metrics.xy), texcoord.xyxy);
        float4 color_1 = colorTex.sample(colorTexSmplr, blendingCoord.xy, level(0.0)) * blendingWeight.x;
        color_1 += (colorTex.sample(colorTexSmplr, blendingCoord.zw, level(0.0)) * blendingWeight.y);
        return color_1;
    }
}

fragment smaaBlendFragment_out smaaBlendFragment(smaaBlendFragment_in in [[stage_in]], constant SMAAParams& _180 [[buffer(0)]], texture2d<float> colorTex [[texture(1)]], texture2d<float> blendTex [[texture(2)]], sampler colorTexSmplr [[sampler(1)]], sampler blendTexSmplr [[sampler(2)]])
{
    smaaBlendFragment_out out = {};
    float2 param = in.v_uv;
    float4 param_1 = in.v_offset;
    out.o_color = SMAANeighborhoodBlendingPS(param, param_1, colorTex, colorTexSmplr, blendTex, blendTexSmplr, _180);
    return out;
}

