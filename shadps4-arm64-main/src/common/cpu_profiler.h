// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

namespace Common::Profiler {

// The sampling CPU profiler of the diagnostics mode (SHADPS4_DIAGNOSTICS=1), for where there is no
// other (the headset): about a thousand times a second a thread of its own stops each registered
// thread, reads its stack and lets it go on. Every 30 s and at the session's end it adds what it
// counted to cpuprof-<date>.txt next to the logs, for tools/symbolize_cpuprof.py. Without the
// diagnostics mode, or with SHADPS4_CPU_PROFILE_OFF=1, nothing is made: no thread, no table.

#ifdef SHADPS4_VISIONOS
/// The calling thread is sampled from now on, under `name`.
void RegisterThread(const char* name);
/// Writes what is left and ends the sampling.
void Stop();
#else
inline void RegisterThread(const char*) {}
inline void Stop() {}
#endif

} // namespace Common::Profiler
