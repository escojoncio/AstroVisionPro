// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

namespace Common::Profiler {

// The sampling CPU profiler, for where there is no other (the headset): 500 times a second a
// thread of its own stops each registered thread, reads its stack and lets it go on. Every 30 s
// and at the session's end it adds what it counted to cpuprof-<date>.txt next to the logs, for
// tools/symbolize_cpuprof.py. It is off, with nothing made (no thread, no table), unless the
// diagnostics mode is on (SHADPS4_DIAGNOSTICS=1) and SHADPS4_CPU_PROFILE=1 asks for it: it
// changes what the session's other measurements say.

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
