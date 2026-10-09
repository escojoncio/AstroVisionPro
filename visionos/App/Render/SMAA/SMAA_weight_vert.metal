// SMAA (Enhanced Subpixel Morphological Antialiasing), weight pass, vert stage.
// Generated from SMAA.hlsl (https://github.com/iryoku/smaa, MIT licence, Copyright (C) 2013
// Jorge Jimenez, Jose I. Echevarria, Belen Masia, Fernando Navarro, Diego Gutierrez) and the
// GLSL entry points in visionos/scripts/smaa/ through glslang and SPIRV-Cross
// (visionos/scripts/smaa/generate.sh). Do not edit: generate it again.

#pragma clang diagnostic ignored "-Wmissing-prototypes"
#pragma clang diagnostic ignored "-Wmissing-braces"

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

template<typename T, size_t Num>
struct spvUnsafeArray
{
    T elements[Num ? Num : 1];
    
    thread T& operator [] (size_t pos) thread
    {
        return elements[pos];
    }
    constexpr const thread T& operator [] (size_t pos) const thread
    {
        return elements[pos];
    }
    
    device T& operator [] (size_t pos) device
    {
        return elements[pos];
    }
    constexpr const device T& operator [] (size_t pos) const device
    {
        return elements[pos];
    }
    
    constexpr const constant T& operator [] (size_t pos) const constant
    {
        return elements[pos];
    }
    
    threadgroup T& operator [] (size_t pos) threadgroup
    {
        return elements[pos];
    }
    constexpr const threadgroup T& operator [] (size_t pos) const threadgroup
    {
        return elements[pos];
    }
};

struct SMAAParams
{
    float4 rt_metrics;
};

struct smaaWeightVertex_out
{
    float2 v_uv [[user(locn0)]];
    float2 v_pixcoord [[user(locn1)]];
    float4 v_offset0 [[user(locn2)]];
    float4 v_offset1 [[user(locn3)]];
    float4 v_offset2 [[user(locn4)]];
    float4 gl_Position [[position]];
};

static inline __attribute__((always_inline))
void SMAABlendingWeightCalculationVS(thread const float2& texcoord, thread float2& pixcoord, thread spvUnsafeArray<float4, 3>& offset, constant SMAAParams& _23)
{
    pixcoord = texcoord * _23.rt_metrics.zw;
    offset[0] = fma(_23.rt_metrics.xyxy, float4(-0.25, -0.125, 1.25, -0.125), texcoord.xyxy);
    offset[1] = fma(_23.rt_metrics.xyxy, float4(-0.125, -0.25, -0.125, 1.25), texcoord.xyxy);
    offset[2] = fma(_23.rt_metrics.xxyy, float4(-32.0, 32.0, -32.0, 32.0), float4(offset[0].xz, offset[1].yw));
}

vertex smaaWeightVertex_out smaaWeightVertex(constant SMAAParams& _23 [[buffer(0)]], uint gl_VertexIndex [[vertex_id]])
{
    smaaWeightVertex_out out = {};
    float2 ndc = float2((int(gl_VertexIndex) == 1) ? 3.0 : (-1.0), (int(gl_VertexIndex) == 2) ? 3.0 : (-1.0));
    out.gl_Position = float4(ndc, 0.0, 1.0);
    out.v_uv = float2((ndc.x * 0.5) + 0.5, 0.5 - (ndc.y * 0.5));
    float2 param = out.v_uv;
    float2 param_1;
    spvUnsafeArray<float4, 3> param_2;
    SMAABlendingWeightCalculationVS(param, param_1, param_2, _23);
    float2 pixcoord = param_1;
    spvUnsafeArray<float4, 3> offset = param_2;
    out.v_pixcoord = pixcoord;
    out.v_offset0 = offset[0];
    out.v_offset1 = offset[1];
    out.v_offset2 = offset[2];
    return out;
}

