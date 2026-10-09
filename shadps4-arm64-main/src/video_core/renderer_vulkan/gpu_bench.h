// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <span>
#include <string>
#include "common/types.h"

// A test of where the GPU's time goes, on a device without a GPU profiler: once started, the
// draws are made five ways in turn, ten seconds each, twice over - as they are, without their
// pixels (rasterizer discard: only their vertices run), with three vertices each (next to no
// geometry), without the passes that have depth and no colour (shadows, depth prepass) and
// without the draws that have a geometry shader. Each change goes to the log as
// "GPU_BENCH: step i of n: <way>", and the GPU_TIME lines after it tell what the GPU took.
namespace Vulkan::GpuBench {

enum class Mode {
    Normal,
    NoFragments,
    NoGeometry,
    NoDepthOnlyPasses,
    NoGeometryShaders,
};

/// Starts the test (again, if it was running). SHADPS4_GPU_BENCH chooses which: "stages" the
/// one above; anything else (the default) the shader test below.
void Start();
/// The way the draws are made now (Normal while the shader test runs).
Mode Current();

// The shader test: what each pixel shader of the scene costs the GPU, measured by leaving its
// draws out (an Apple GPU times only whole passes). For 4 s the draws of the scene passes (with
// depth and a colour target, at least 1024 wide) are counted by pixel shader; for the heaviest
// (by draws and by vertices, up to 8) come steps of 3 s: as they are, the shader's draws without
// their pixels (vertices only), without its draws; lastly all of them left out at once, between
// steps as they are. Each step's GPU time a frame (and its scene passes' time) is measured on
// its own (TimingTag, NoteGpuTime, NoteFrame), and at the end "GPU_SHADER_BENCH: result" says
// what each change saved.

/// What the shader test does to a draw.
enum class DrawAction { Draw, NoPixels, Skip };

/// Whether the shader test is running (counting or leaving draws out).
bool ShaderTestRunning();
/// A draw in a pass with these targets (shader test): counted, and what is to be done to it
/// now. `vertices` is 0 when not known (indirect draws).
DrawAction ShaderDraw(bool scene_pass, u64 fs_hash, u64 vs_hash, bool has_gs, u64 vertices);
/// For a command buffer begun (or ended) now: the step of the shader test its GPU time
/// belongs to, or -1 (no test, counting, or a step's first half second).
int TimingTag();
/// The GPU took `ms` (negative: no usable time) for a command buffer tagged `tag`, `scene_ms` of
/// it in scene passes (timed on their own), timed
/// by the timer `timer` (each scheduler has its own; the game's is the one with the most time).
void NoteGpuTime(u32 timer, int tag, double ms, double scene_ms);
/// A frame was presented (FrameStats::EndFrame).
void NoteFrame();
/// While counting: whether the state of a draw with this pixel shader (key hash) is still
/// wanted, and that state, logged with each candidate.
bool WantsShaderState(u64 fs_hash);
void NoteShaderState(u64 fs_hash, std::string text);
/// A shader compiled to SPIR-V, by its key hash (HashCombine(program hash, permutation)): kept
/// so that the candidates' SPIR-V goes to the log ("GPU_SHADER_SPIRV", base64), to be read
/// off the device.
void NoteSpirv(u64 key_hash, std::span<const u32> spirv);

} // namespace Vulkan::GpuBench
