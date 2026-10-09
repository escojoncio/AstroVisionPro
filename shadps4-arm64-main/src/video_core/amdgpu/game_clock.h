// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include "common/types.h"

// The GPU clocks a title reads through its end-of-pipe events (EVENT_WRITE_EOP, RELEASE_MEM
// with DATA_SEL 3 or 4). Emulated, they are stamped when the command processor reaches the
// event, so the time between two of them is how long the emulator took to pass the drawing on,
// waits for a saturated host GPU included. A title that sizes its work by them (fewer shadows
// and effects when its GPU looks slow) sees that.
//
// SHADPS4_GPU_CLOCK_SCALE=<factor> (0.1 to 1; 1 by default) makes both clocks run at that
// fraction of real time from the first stamp on: everything the title times with them looks that
// much shorter.
//
// SHADPS4_GPU_CLOCK_SCALE=auto: they run at a factor set every frame from what the title
// measured (SetFactor, from KnownTitle::OnFrameSubmitted) and are put back on real time when the
// command processor starts on a new frame (OnFrameDone), so they never drift further than that.
// SHADPS4_GPU_STAMP_LOG=1 writes to the log, every few seconds, the stamps of a
// tenth of a second (where they go, how far apart) so that what the title measures can be seen.
namespace AmdGpu::GameClock {

/// The 64-bit GPU clock (DATA_SEL 3), in nanoseconds of the host's clock, scaled.
u64 GpuClock64();
/// The GPU performance counter (DATA_SEL 4), in the GPU's core cycles, scaled.
u64 PerfCounter();
/// A stamp written to the title's memory, for the log.
void NoteStamp(const void* address, u64 value, bool perf_counter);
/// A mark in the log from the player (a controller combination): what was seen then.
void NoteMark();

/// Whether the clocks are automatic (SHADPS4_GPU_CLOCK_SCALE=auto).
bool IsAutomatic();
/// The factor the automatic clocks run at from now on (clamped to 0.1 to 1).
void SetFactor(double factor);
/// The factor in effect (the fixed one when not automatic).
double Factor();
/// The command processor starts on a new frame: the automatic clocks go back to real time.
void OnFrameDone();
/// Put back on real time if no frame has ended for a while (called at every stamp).
void ResyncIfLate();

struct ResyncStats {
    u64 frames{};      ///< Put back at a frame's end.
    u64 late{};        ///< Put back because no frame ended for a while.
    double catch_up_ms{}; ///< How far forward the 64-bit clock moved at those, in all.
};
/// What happened since the last call.
ResyncStats TakeResyncStats();

} // namespace AmdGpu::GameClock
