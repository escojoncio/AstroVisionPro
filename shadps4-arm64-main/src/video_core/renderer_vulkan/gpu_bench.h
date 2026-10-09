// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

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

/// Starts the test (again, if it was running).
void Start();
/// The way the draws are made now.
Mode Current();

} // namespace Vulkan::GpuBench
