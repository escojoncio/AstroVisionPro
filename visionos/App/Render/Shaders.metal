// SPDX-License-Identifier: GPL-2.0-or-later
//
// Puts the game's picture in front of the eyes, the way an OpenXR compositor shows the
// projection layer the PC build hands it (shadps4-arm64-main/src/core/vr/openxr_host.cpp,
// FillProjection): every pixel of the headset's view looks in some direction; that direction,
// seen from the head pose the game drew the frame for, falls somewhere on the game's picture of
// that eye, drawn with its field of view. So the picture stays where it was drawn while the head
// turns on - the reprojection PlayStation VR did itself for this game.
//
// It draws one triangle that covers the whole view, once per eye (vertex amplification, or one
// pass per eye), through the drawable's rasterization rate map when foveation is on.

#include <metal_stdlib>
#include <simd/simd.h>

#import "ShaderTypes.h"

using namespace metal;

struct ViewOut {
    float4 position [[position]];
    /// The direction this pixel looks in, in the game eye's space (not normalized: it is linear
    /// in the pixel's position, so it is interpolated exactly).
    float3 direction [[center_no_perspective]];
    ushort eye [[flat]];
};

vertex ViewOut fullscreenVertex(uint vertex_id [[vertex_id]],
                                ushort amplification_id [[amplification_id]],
                                constant AstroFrameUniforms& uniforms [[buffer(0)]],
                                constant uint& eye_base [[buffer(1)]]) {
    // One triangle over the whole view: (-1,-1), (3,-1), (-1,3).
    const float2 ndc = float2(vertex_id == 1 ? 3.0 : -1.0, vertex_id == 2 ? 3.0 : -1.0);
    const ushort eye = ushort(eye_base) + amplification_id;
    constant AstroEyeUniforms& u = uniforms.eyes[eye];
    const float3 p = float3(ndc, 1.0);
    ViewOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.direction = float3(dot(u.ray_x.xyz, p), dot(u.ray_y.xyz, p), dot(u.ray_z.xyz, p));
    out.eye = eye;
    return out;
}

fragment half4 reprojectFragment(ViewOut in [[stage_in]],
                                 constant AstroFrameUniforms& uniforms [[buffer(0)]],
                                 texture2d<half> left_eye [[texture(0)]],
                                 texture2d<half> right_eye [[texture(1)]]) {
    constexpr sampler linear_sampler(coord::normalized, filter::linear, address::clamp_to_edge);
    constant AstroEyeUniforms& u = uniforms.eyes[in.eye];
    if (u.has_frame < 0.5) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }
    const float3 d = in.direction;
    // Looking away from where the game's eye looks: nothing it drew.
    if (d.z > -1e-4) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }
    // Where on the game eye's picture plane (at distance one) the pixel looks.
    const float tx = d.x / -d.z;
    const float ty = d.y / -d.z;
    const float left = u.tangents.x;
    const float right = u.tangents.y;
    const float up = u.tangents.z;
    const float down = u.tangents.w;
    const float s = (tx + left) / (left + right);
    const float t = (up - ty) / (up + down);
    // What the game did not draw (around the edges of its field of view) stays black, as the
    // PC build's compositor shows it.
    if (s < 0.0 || s > 1.0 || t < 0.0 || t > 1.0) {
        return half4(0.0h, 0.0h, 0.0h, 1.0h);
    }
    // Into this eye's picture (its half of the frame, or a texture of its own), not sampling
    // across into the other eye's.
    const float x = clamp(u.frame_x.x + s * u.frame_x.y, u.frame_x.z, u.frame_x.w);
    const float2 at = float2(x, t);
    const half3 color = in.eye == 0 ? left_eye.sample(linear_sampler, at).rgb
                                    : right_eye.sample(linear_sampler, at).rgb;
    return half4(color, 1.0h);
}

// Edge smoothing (FXAA, after Timothy Lottes' FXAA): once per frame of the game's, its picture
// (both eyes side by side) is redrawn into a texture of the same size with the stair steps of
// its edges blended along each edge. A sample never crosses into the other eye.

struct EdgeOut {
    float4 position [[position]];
    float2 uv;
};

vertex EdgeOut edgeVertex(uint vertex_id [[vertex_id]]) {
    const float2 ndc = float2(vertex_id == 1 ? 3.0f : -1.0f, vertex_id == 2 ? 3.0f : -1.0f);
    EdgeOut out;
    out.position = float4(ndc, 0.0f, 1.0f);
    out.uv = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
    return out;
}

static float3 edgeAt(texture2d<float> picture, float2 uv, float lo, float hi) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return picture.sample(s, float2(clamp(uv.x, lo, hi), uv.y)).rgb;
}

static float edgeLuma(float3 linear_rgb) {
    return dot(sqrt(max(linear_rgb, 0.0f)), float3(0.299f, 0.587f, 0.114f));
}

fragment float4 edgeFragment(EdgeOut in [[stage_in]],
                             texture2d<float> picture [[texture(0)]],
                             constant float2& texel [[buffer(0)]]) {
    const float lo = (in.uv.x < 0.5f ? 0.0f : 0.5f) + texel.x * 0.5f;
    const float hi = lo + 0.5f - texel.x;

    const float3 rgbM = edgeAt(picture, in.uv, lo, hi);
    const float lumaM = edgeLuma(rgbM);
    const float lumaNW = edgeLuma(edgeAt(picture, in.uv + float2(-1.0f, -1.0f) * texel, lo, hi));
    const float lumaNE = edgeLuma(edgeAt(picture, in.uv + float2(1.0f, -1.0f) * texel, lo, hi));
    const float lumaSW = edgeLuma(edgeAt(picture, in.uv + float2(-1.0f, 1.0f) * texel, lo, hi));
    const float lumaSE = edgeLuma(edgeAt(picture, in.uv + float2(1.0f, 1.0f) * texel, lo, hi));
    const float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    const float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));
    if (lumaMax - lumaMin < max(0.0312f, lumaMax * 0.125f)) {
        return float4(rgbM, 1.0f);
    }

    float2 dir = float2(-((lumaNW + lumaNE) - (lumaSW + lumaSE)),
                        (lumaNW + lumaSW) - (lumaNE + lumaSE));
    const float reduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * (0.25f / 8.0f), 1.0f / 128.0f);
    const float scale = 1.0f / (min(abs(dir.x), abs(dir.y)) + reduce);
    dir = clamp(dir * scale, float2(-8.0f), float2(8.0f)) * texel;

    const float3 rgbA = 0.5f * (edgeAt(picture, in.uv + dir * (1.0f / 3.0f - 0.5f), lo, hi) +
                               edgeAt(picture, in.uv + dir * (2.0f / 3.0f - 0.5f), lo, hi));
    const float3 rgbB = rgbA * 0.5f + 0.25f * (edgeAt(picture, in.uv - dir * 0.5f, lo, hi) + edgeAt(picture, in.uv + dir * 0.5f, lo, hi));
    const float lumaB = edgeLuma(rgbB);
    return float4((lumaB < lumaMin || lumaB > lumaMax) ? rgbA : rgbB, 1.0f);
}
