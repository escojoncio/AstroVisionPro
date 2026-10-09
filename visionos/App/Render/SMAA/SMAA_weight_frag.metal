// SMAA (Enhanced Subpixel Morphological Antialiasing), weight pass, frag stage.
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

struct smaaWeightFragment_out
{
    float4 o_weights [[color(0)]];
};

struct smaaWeightFragment_in
{
    float2 v_uv [[user(locn0)]];
    float2 v_pixcoord [[user(locn1)]];
    float4 v_offset0 [[user(locn2)]];
    float4 v_offset1 [[user(locn3)]];
    float4 v_offset2 [[user(locn4)]];
};

static inline __attribute__((always_inline))
float2 SMAASearchDiag1(texture2d<float> edgesTex, sampler edgesTexSmplr, thread const float2& texcoord, thread const float2& dir, thread float2& e, constant SMAAParams& _188)
{
    float4 coord = float4(texcoord, -1.0, 1.0);
    float3 t = float3(_188.rt_metrics.xy, 1.0);
    for (;;)
    {
        bool _206 = coord.z < 7.0;
        bool _213;
        if (_206)
        {
            _213 = coord.w > 0.89999997615814208984375;
        }
        else
        {
            _213 = _206;
        }
        if (_213)
        {
            float4 _219 = coord;
            float3 _221 = fma(t, float3(dir, 1.0), _219.xyz);
            coord.x = _221.x;
            coord.y = _221.y;
            coord.z = _221.z;
            e = edgesTex.sample(edgesTexSmplr, coord.xy, level(0.0)).xy;
            coord.w = dot(e, float2(0.5));
            continue;
        }
        else
        {
            break;
        }
    }
    return coord.zw;
}

static inline __attribute__((always_inline))
float4 SMAADecodeDiagBilinearAccess(thread float4& e)
{
    float4 _158 = e;
    float4 _160 = e;
    float2 _166 = _158.xz * abs((_160.xz * 5.0) - float2(3.75));
    e.x = _166.x;
    e.z = _166.y;
    return round(e);
}

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
float2 SMAAAreaDiag(texture2d<float> areaTex, sampler areaTexSmplr, thread const float2& dist, thread const float2& e, thread const float& offset)
{
    float2 texcoord = fma(float2(20.0), e, dist);
    texcoord = fma(float2(0.0062500000931322574615478515625, 0.001785714295692741870880126953125), texcoord, float2(0.00312500004656612873077392578125, 0.0008928571478463709354400634765625));
    texcoord.x += 0.5;
    texcoord.y += (0.14285714924335479736328125 * offset);
    return areaTex.sample(areaTexSmplr, texcoord, level(0.0)).xy;
}

static inline __attribute__((always_inline))
float2 SMAADecodeDiagBilinearAccess(thread float2& e)
{
    e.x *= abs((5.0 * e.x) - 3.75);
    return round(e);
}

static inline __attribute__((always_inline))
float2 SMAASearchDiag2(texture2d<float> edgesTex, sampler edgesTexSmplr, thread const float2& texcoord, thread const float2& dir, thread float2& e, constant SMAAParams& _188)
{
    float4 coord = float4(texcoord, -1.0, 1.0);
    coord.x += (0.25 * _188.rt_metrics.x);
    float3 t = float3(_188.rt_metrics.xy, 1.0);
    for (;;)
    {
        bool _271 = coord.z < 7.0;
        bool _277;
        if (_271)
        {
            _277 = coord.w > 0.89999997615814208984375;
        }
        else
        {
            _277 = _271;
        }
        if (_277)
        {
            float4 _283 = coord;
            float3 _285 = fma(t, float3(dir, 1.0), _283.xyz);
            coord.x = _285.x;
            coord.y = _285.y;
            coord.z = _285.z;
            e = edgesTex.sample(edgesTexSmplr, coord.xy, level(0.0)).xy;
            float2 param = e;
            float2 _299 = SMAADecodeDiagBilinearAccess(param);
            e = _299;
            coord.w = dot(e, float2(0.5));
            continue;
        }
        else
        {
            break;
        }
    }
    return coord.zw;
}

static inline __attribute__((always_inline))
float2 SMAACalculateDiagWeights(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> areaTex, sampler areaTexSmplr, thread const float2& texcoord, thread const float2& e, thread const float4& subsampleIndices, constant SMAAParams& _188)
{
    float2 weights = float2(0.0);
    float4 d;
    float2 end;
    if (e.x > 0.0)
    {
        float2 param = texcoord;
        float2 param_1 = float2(-1.0, 1.0);
        float2 param_2;
        float2 _352 = SMAASearchDiag1(edgesTex, edgesTexSmplr, param, param_1, param_2, _188);
        end = param_2;
        d.x = _352.x;
        d.z = _352.y;
        d.x += float(end.y > 0.89999997615814208984375);
    }
    else
    {
        d.x = 0.0;
        d.z = 0.0;
    }
    float2 param_3 = texcoord;
    float2 param_4 = float2(1.0, -1.0);
    float2 param_5;
    float2 _376 = SMAASearchDiag1(edgesTex, edgesTexSmplr, param_3, param_4, param_5, _188);
    end = param_5;
    d.y = _376.x;
    d.w = _376.y;
    if ((d.x + d.y) > 2.0)
    {
        float4 coords = fma(float4((-d.x) + 0.25, d.x, d.y, (-d.y) - 0.25), _188.rt_metrics.xyxy, texcoord.xyxy);
        float2 _419 = edgesTex.sample(edgesTexSmplr, coords.xy, level(0.0), int2(-1, 0)).xy;
        float4 c;
        c.x = _419.x;
        c.y = _419.y;
        float2 _430 = edgesTex.sample(edgesTexSmplr, coords.zw, level(0.0), int2(1, 0)).xy;
        c.z = _430.x;
        c.w = _430.y;
        float4 param_6 = c;
        float4 _437 = SMAADecodeDiagBilinearAccess(param_6);
        c = float4(_437.y, _437.x, _437.w, _437.z);
        float2 cc = fma(float2(2.0), c.xz, c.yw);
        bool2 param_7 = step(float2(0.89999997615814208984375), d.zw) != float2(0.0);
        float2 param_8 = cc;
        float2 param_9 = float2(0.0);
        SMAAMovc(param_7, param_8, param_9);
        cc = param_8;
        float2 param_10 = d.xy;
        float2 param_11 = cc;
        float param_12 = subsampleIndices.z;
        weights += SMAAAreaDiag(areaTex, areaTexSmplr, param_10, param_11, param_12);
    }
    float2 param_13 = texcoord;
    float2 param_14 = float2(-1.0);
    float2 param_15;
    float2 _474 = SMAASearchDiag2(edgesTex, edgesTexSmplr, param_13, param_14, param_15, _188);
    end = param_15;
    d.x = _474.x;
    d.z = _474.y;
    if (edgesTex.sample(edgesTexSmplr, texcoord, level(0.0), int2(1, 0)).x > 0.0)
    {
        float2 param_16 = texcoord;
        float2 param_17 = float2(1.0);
        float2 param_18;
        float2 _492 = SMAASearchDiag2(edgesTex, edgesTexSmplr, param_16, param_17, param_18, _188);
        end = param_18;
        d.y = _492.x;
        d.w = _492.y;
        d.y += float(end.y > 0.89999997615814208984375);
    }
    else
    {
        d.y = 0.0;
        d.w = 0.0;
    }
    if ((d.x + d.y) > 2.0)
    {
        float4 coords_1 = fma(float4(-d.x, -d.x, d.y, d.y), _188.rt_metrics.xyxy, texcoord.xyxy);
        float4 c_1;
        c_1.x = edgesTex.sample(edgesTexSmplr, coords_1.xy, level(0.0), int2(-1, 0)).y;
        c_1.y = edgesTex.sample(edgesTexSmplr, coords_1.xy, level(0.0), int2(0, -1)).x;
        float2 _555 = edgesTex.sample(edgesTexSmplr, coords_1.zw, level(0.0), int2(1, 0)).yx;
        c_1.z = _555.x;
        c_1.w = _555.y;
        float2 cc_1 = fma(float2(2.0), c_1.xz, c_1.yw);
        bool2 param_19 = step(float2(0.89999997615814208984375), d.zw) != float2(0.0);
        float2 param_20 = cc_1;
        float2 param_21 = float2(0.0);
        SMAAMovc(param_19, param_20, param_21);
        cc_1 = param_20;
        float2 param_22 = d.xy;
        float2 param_23 = cc_1;
        float param_24 = subsampleIndices.w;
        weights += SMAAAreaDiag(areaTex, areaTexSmplr, param_22, param_23, param_24).yx;
    }
    return weights;
}

static inline __attribute__((always_inline))
float SMAASearchLength(texture2d<float> searchTex, sampler searchTexSmplr, thread const float2& e, thread const float& offset)
{
    float2 scale = float2(33.0, -33.0);
    float2 bias0 = float2(66.0, 33.0) * float2(offset, 1.0);
    scale += float2(-1.0, 1.0);
    bias0 += float2(0.5, -0.5);
    scale *= float2(0.015625, 0.0625);
    bias0 *= float2(0.015625, 0.0625);
    return searchTex.sample(searchTexSmplr, fma(scale, e, bias0), level(0.0)).x;
}

static inline __attribute__((always_inline))
float SMAASearchXLeft(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread float2& texcoord, thread const float& end, constant SMAAParams& _188)
{
    float2 e = float2(0.0, 1.0);
    for (;;)
    {
        bool _634 = texcoord.x > end;
        bool _641;
        if (_634)
        {
            _641 = e.y > 0.828100025653839111328125;
        }
        else
        {
            _641 = _634;
        }
        bool _647;
        if (_641)
        {
            _647 = e.x == 0.0;
        }
        else
        {
            _647 = _641;
        }
        if (_647)
        {
            e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
            texcoord = fma(float2(-2.0, -0.0), _188.rt_metrics.xy, texcoord);
            continue;
        }
        else
        {
            break;
        }
    }
    float2 param = e;
    float param_1 = 0.0;
    float offset = fma(-2.007874011993408203125, SMAASearchLength(searchTex, searchTexSmplr, param, param_1), 3.25);
    return fma(_188.rt_metrics.x, offset, texcoord.x);
}

static inline __attribute__((always_inline))
float SMAASearchXRight(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread float2& texcoord, thread const float& end, constant SMAAParams& _188)
{
    float2 e = float2(0.0, 1.0);
    for (;;)
    {
        bool _685 = texcoord.x < end;
        bool _691;
        if (_685)
        {
            _691 = e.y > 0.828100025653839111328125;
        }
        else
        {
            _691 = _685;
        }
        bool _697;
        if (_691)
        {
            _697 = e.x == 0.0;
        }
        else
        {
            _697 = _691;
        }
        if (_697)
        {
            e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
            texcoord = fma(float2(2.0, 0.0), _188.rt_metrics.xy, texcoord);
            continue;
        }
        else
        {
            break;
        }
    }
    float2 param = e;
    float param_1 = 0.5;
    float offset = fma(-2.007874011993408203125, SMAASearchLength(searchTex, searchTexSmplr, param, param_1), 3.25);
    return fma(-_188.rt_metrics.x, offset, texcoord.x);
}

static inline __attribute__((always_inline))
float2 SMAAArea(texture2d<float> areaTex, sampler areaTexSmplr, thread const float2& dist, thread const float& e1, thread const float& e2, thread const float& offset)
{
    float2 texcoord = fma(float2(16.0), round(float2(e1, e2) * 4.0), dist);
    texcoord = fma(float2(0.0062500000931322574615478515625, 0.001785714295692741870880126953125), texcoord, float2(0.00312500004656612873077392578125, 0.0008928571478463709354400634765625));
    texcoord.y = fma(0.14285714924335479736328125, offset, texcoord.y);
    return areaTex.sample(areaTexSmplr, texcoord, level(0.0)).xy;
}

static inline __attribute__((always_inline))
void SMAADetectHorizontalCornerPattern(texture2d<float> edgesTex, sampler edgesTexSmplr, thread float2& weights, thread const float4& texcoord, thread const float2& d)
{
    float2 leftRight = step(d, d.yx);
    float2 rounding = leftRight * 0.75;
    rounding /= float2(leftRight.x + leftRight.y);
    float2 factor = float2(1.0);
    factor.x -= (rounding.x * edgesTex.sample(edgesTexSmplr, texcoord.xy, level(0.0), int2(0, 1)).x);
    factor.x -= (rounding.y * edgesTex.sample(edgesTexSmplr, texcoord.zw, level(0.0), int2(1)).x);
    factor.y -= (rounding.x * edgesTex.sample(edgesTexSmplr, texcoord.xy, level(0.0), int2(0, -2)).x);
    factor.y -= (rounding.y * edgesTex.sample(edgesTexSmplr, texcoord.zw, level(0.0), int2(1, -2)).x);
    weights *= fast::clamp(factor, float2(0.0), float2(1.0));
}

static inline __attribute__((always_inline))
float SMAASearchYUp(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread float2& texcoord, thread const float& end, constant SMAAParams& _188)
{
    float2 e = float2(1.0, 0.0);
    for (;;)
    {
        bool _733 = texcoord.y > end;
        bool _739;
        if (_733)
        {
            _739 = e.x > 0.828100025653839111328125;
        }
        else
        {
            _739 = _733;
        }
        bool _745;
        if (_739)
        {
            _745 = e.y == 0.0;
        }
        else
        {
            _745 = _739;
        }
        if (_745)
        {
            e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
            texcoord = fma(float2(-0.0, -2.0), _188.rt_metrics.xy, texcoord);
            continue;
        }
        else
        {
            break;
        }
    }
    float2 param = e.yx;
    float param_1 = 0.0;
    float offset = fma(-2.007874011993408203125, SMAASearchLength(searchTex, searchTexSmplr, param, param_1), 3.25);
    return fma(_188.rt_metrics.y, offset, texcoord.y);
}

static inline __attribute__((always_inline))
float SMAASearchYDown(texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread float2& texcoord, thread const float& end, constant SMAAParams& _188)
{
    float2 e = float2(1.0, 0.0);
    for (;;)
    {
        bool _780 = texcoord.y < end;
        bool _786;
        if (_780)
        {
            _786 = e.x > 0.828100025653839111328125;
        }
        else
        {
            _786 = _780;
        }
        bool _792;
        if (_786)
        {
            _792 = e.y == 0.0;
        }
        else
        {
            _792 = _786;
        }
        if (_792)
        {
            e = edgesTex.sample(edgesTexSmplr, texcoord, level(0.0)).xy;
            texcoord = fma(float2(0.0, 2.0), _188.rt_metrics.xy, texcoord);
            continue;
        }
        else
        {
            break;
        }
    }
    float2 param = e.yx;
    float param_1 = 0.5;
    float offset = fma(-2.007874011993408203125, SMAASearchLength(searchTex, searchTexSmplr, param, param_1), 3.25);
    return fma(-_188.rt_metrics.y, offset, texcoord.y);
}

static inline __attribute__((always_inline))
void SMAADetectVerticalCornerPattern(texture2d<float> edgesTex, sampler edgesTexSmplr, thread float2& weights, thread const float4& texcoord, thread const float2& d)
{
    float2 leftRight = step(d, d.yx);
    float2 rounding = leftRight * 0.75;
    rounding /= float2(leftRight.x + leftRight.y);
    float2 factor = float2(1.0);
    factor.x -= (rounding.x * edgesTex.sample(edgesTexSmplr, texcoord.xy, level(0.0), int2(1, 0)).y);
    factor.x -= (rounding.y * edgesTex.sample(edgesTexSmplr, texcoord.zw, level(0.0), int2(1)).y);
    factor.y -= (rounding.x * edgesTex.sample(edgesTexSmplr, texcoord.xy, level(0.0), int2(-2, 0)).y);
    factor.y -= (rounding.y * edgesTex.sample(edgesTexSmplr, texcoord.zw, level(0.0), int2(-2, 1)).y);
    weights *= fast::clamp(factor, float2(0.0), float2(1.0));
}

static inline __attribute__((always_inline))
float4 SMAABlendingWeightCalculationPS(thread const float2& texcoord, thread const float2& pixcoord, thread const spvUnsafeArray<float4, 3>& offset, texture2d<float> edgesTex, sampler edgesTexSmplr, texture2d<float> areaTex, sampler areaTexSmplr, texture2d<float> searchTex, sampler searchTexSmplr, thread const float4& subsampleIndices, constant SMAAParams& _188)
{
    float4 weights = float4(0.0);
    float2 e = edgesTex.sample(edgesTexSmplr, texcoord).xy;
    if (e.y > 0.0)
    {
        float2 param = texcoord;
        float2 param_1 = e;
        float4 param_2 = subsampleIndices;
        float2 _1011 = SMAACalculateDiagWeights(edgesTex, edgesTexSmplr, areaTex, areaTexSmplr, param, param_1, param_2, _188);
        weights.x = _1011.x;
        weights.y = _1011.y;
        if (weights.x == (-weights.y))
        {
            float2 param_3 = offset[0].xy;
            float param_4 = offset[2].x;
            float _1033 = SMAASearchXLeft(edgesTex, edgesTexSmplr, searchTex, searchTexSmplr, param_3, param_4, _188);
            float3 coords;
            coords.x = _1033;
            coords.y = offset[1].y;
            float2 d;
            d.x = coords.x;
            float e1 = edgesTex.sample(edgesTexSmplr, coords.xy, level(0.0)).x;
            float2 param_5 = offset[0].zw;
            float param_6 = offset[2].y;
            float _1055 = SMAASearchXRight(edgesTex, edgesTexSmplr, searchTex, searchTexSmplr, param_5, param_6, _188);
            coords.z = _1055;
            d.y = coords.z;
            d = abs(round(fma(_188.rt_metrics.zz, d, -pixcoord.xx)));
            float2 sqrt_d = sqrt(d);
            float e2 = edgesTex.sample(edgesTexSmplr, coords.zy, level(0.0), int2(1, 0)).x;
            float2 param_7 = sqrt_d;
            float param_8 = e1;
            float param_9 = e2;
            float param_10 = subsampleIndices.y;
            float2 _1088 = SMAAArea(areaTex, areaTexSmplr, param_7, param_8, param_9, param_10);
            weights.x = _1088.x;
            weights.y = _1088.y;
            coords.y = texcoord.y;
            float2 param_11 = weights.xy;
            float4 param_12 = coords.xyzy;
            float2 param_13 = d;
            SMAADetectHorizontalCornerPattern(edgesTex, edgesTexSmplr, param_11, param_12, param_13);
            weights.x = param_11.x;
            weights.y = param_11.y;
        }
        else
        {
            e.x = 0.0;
        }
    }
    if (e.x > 0.0)
    {
        float2 param_14 = offset[1].xy;
        float param_15 = offset[2].z;
        float _1125 = SMAASearchYUp(edgesTex, edgesTexSmplr, searchTex, searchTexSmplr, param_14, param_15, _188);
        float3 coords_1;
        coords_1.y = _1125;
        coords_1.x = offset[0].x;
        float2 d_1;
        d_1.x = coords_1.y;
        float e1_1 = edgesTex.sample(edgesTexSmplr, coords_1.xy, level(0.0)).y;
        float2 param_16 = offset[1].zw;
        float param_17 = offset[2].w;
        float _1147 = SMAASearchYDown(edgesTex, edgesTexSmplr, searchTex, searchTexSmplr, param_16, param_17, _188);
        coords_1.z = _1147;
        d_1.y = coords_1.z;
        d_1 = abs(round(fma(_188.rt_metrics.ww, d_1, -pixcoord.yy)));
        float2 sqrt_d_1 = sqrt(d_1);
        float e2_1 = edgesTex.sample(edgesTexSmplr, coords_1.xz, level(0.0), int2(0, 1)).y;
        float2 param_18 = sqrt_d_1;
        float param_19 = e1_1;
        float param_20 = e2_1;
        float param_21 = subsampleIndices.x;
        float2 _1180 = SMAAArea(areaTex, areaTexSmplr, param_18, param_19, param_20, param_21);
        weights.z = _1180.x;
        weights.w = _1180.y;
        coords_1.x = texcoord.x;
        float2 param_22 = weights.zw;
        float4 param_23 = coords_1.xyxz;
        float2 param_24 = d_1;
        SMAADetectVerticalCornerPattern(edgesTex, edgesTexSmplr, param_22, param_23, param_24);
        weights.z = param_22.x;
        weights.w = param_22.y;
    }
    return weights;
}

fragment smaaWeightFragment_out smaaWeightFragment(smaaWeightFragment_in in [[stage_in]], constant SMAAParams& _188 [[buffer(0)]], texture2d<float> edgesTex [[texture(1)]], texture2d<float> areaTex [[texture(2)]], texture2d<float> searchTex [[texture(3)]], sampler edgesTexSmplr [[sampler(1)]], sampler areaTexSmplr [[sampler(2)]], sampler searchTexSmplr [[sampler(3)]])
{
    smaaWeightFragment_out out = {};
    spvUnsafeArray<float4, 3> offset;
    offset[0] = in.v_offset0;
    offset[1] = in.v_offset1;
    offset[2] = in.v_offset2;
    float2 param = in.v_uv;
    float2 param_1 = in.v_pixcoord;
    spvUnsafeArray<float4, 3> param_2 = offset;
    float4 param_3 = float4(0.0);
    out.o_weights = SMAABlendingWeightCalculationPS(param, param_1, param_2, edgesTex, edgesTexSmplr, areaTex, areaTexSmplr, searchTex, searchTexSmplr, param_3, _188);
    return out;
}

