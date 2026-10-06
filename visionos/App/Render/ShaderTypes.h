// SPDX-License-Identifier: GPL-2.0-or-later
// What the frame loop (GameRenderer.swift) hands the shaders (Shaders.metal).
#pragma once

#include <simd/simd.h>

/// For one eye of the headset: how to go from a pixel of its drawable to a direction in the
/// space of the eye the game drew the frame for, and where that eye's picture is in the frame.
typedef struct {
    /// Rows of the matrix that turns (ndc.x, ndc.y, 1) - a pixel by its normalized device
    /// coordinates on the drawable - into the direction it looks in, in the space of the game's
    /// eye: the view's projection undone, the view's orientation in the world, and the
    /// orientation of the head pose the game drew the frame for, undone.
    simd_float4 ray_x;
    simd_float4 ray_y;
    simd_float4 ray_z;
    /// Tangents of the half angles the game drew this eye with: left, right, up, down.
    simd_float4 tangents;
    /// Where this eye's picture is in the frame texture, in texture coordinates: the left edge
    /// and the width (the eyes are side by side), then the same for the half texel at either
    /// edge that is not to be sampled across.
    simd_float4 frame_x;
    /// 1 when there is a frame to show at all.
    float has_frame;
    float padding[3];
} AstroEyeUniforms;

typedef struct {
    AstroEyeUniforms eyes[2];
} AstroFrameUniforms;
