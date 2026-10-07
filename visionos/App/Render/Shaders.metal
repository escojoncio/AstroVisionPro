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
                                 texture2d<half> frame [[texture(0)]]) {
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
    // For now, a thin blue line along the edges of the game's picture: it shows that frames
    // arrive and where they land, even while what the game draws is black.
    constexpr float edge = 0.004;
    if (s < edge || s > 1.0 - edge || t < edge || t > 1.0 - edge) {
        return half4(0.0h, 0.4h, 1.0h, 1.0h);
    }
    // Into this eye's half of the frame, not sampling across into the other eye's.
    const float x = clamp(u.frame_x.x + s * u.frame_x.y, u.frame_x.z, u.frame_x.w);
    const half3 color = frame.sample(linear_sampler, float2(x, t)).rgb;
    return half4(color, 1.0h);
}
