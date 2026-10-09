// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdlib>
#include <mutex>
#include <string>
#include <fmt/format.h>

#include "common/logging/log.h"
#include "common/uint128.h"
#include "core/libraries/gnmdriver/gnmdriver.h"
#include "core/libraries/kernel/time.h"
#include "video_core/amdgpu/game_clock.h"

namespace AmdGpu::GameClock {

namespace {

double Scale() {
    static const double scale = [] {
        const char* value = std::getenv("SHADPS4_GPU_CLOCK_SCALE");
        // Read by hand: atof would follow the C locale's decimal mark.
        double parsed = 1.0;
        if (value != nullptr) {
            double whole = 0.0;
            double fraction = 0.0;
            double place = 0.1;
            bool after_mark = false;
            bool digits = false;
            for (const char* c = value; *c != '\0'; ++c) {
                if (*c >= '0' && *c <= '9') {
                    digits = true;
                    if (after_mark) {
                        fraction += (*c - '0') * place;
                        place /= 10.0;
                    } else {
                        whole = whole * 10.0 + (*c - '0');
                    }
                } else if ((*c == '.' || *c == ',') && !after_mark) {
                    after_mark = true;
                } else {
                    digits = false;
                    break;
                }
            }
            parsed = digits ? whole + fraction : 1.0;
        }
        const double result = parsed > 0.0 ? std::clamp(parsed, 0.1, 1.0) : 1.0;
        if (result != 1.0) {
            LOG_INFO(Lib_GnmDriver,
                     "GPU_CLOCK: the title's GPU clocks run at {:.2f} of real time (what it times "
                     "with them looks that much shorter)",
                     result);
        }
        return result;
    }();
    return scale;
}

bool StampLog() {
    static const bool on = [] {
        const char* value = std::getenv("SHADPS4_GPU_STAMP_LOG");
        return value != nullptr && value[0] == '1';
    }();
    return on;
}

/// A clock that runs at Scale() of the raw one from its first reading on.
class Scaled {
public:
    u64 Get(u64 raw) {
        const double scale = Scale();
        if (scale == 1.0) {
            return raw;
        }
        std::call_once(once, [&] { anchor = raw; });
        if (raw >= anchor) {
            return anchor + static_cast<u64>(static_cast<double>(raw - anchor) * scale);
        }
        return anchor - static_cast<u64>(static_cast<double>(anchor - raw) * scale);
    }

private:
    std::once_flag once;
    u64 anchor{};
};

Scaled clock64;
Scaled perf_counter;

u64 RawClock64() {
    const auto now = std::chrono::high_resolution_clock::now().time_since_epoch();
    return static_cast<u64>(std::chrono::duration_cast<std::chrono::nanoseconds>(now).count());
}

u64 GpuFrequency() {
    return Libraries::GnmDriver::sceGnmGetGpuCoreClockFrequency();
}

u64 RawPerfCounter() {
    const auto cpu_freq = Libraries::Kernel::sceKernelGetTscFrequency();
    const auto cpu_cycles = Libraries::Kernel::sceKernelReadTsc();
    if (cpu_freq == 0) {
        return cpu_cycles;
    }
    return Common::MultiplyAndDivide64(cpu_cycles, GpuFrequency(), cpu_freq);
}

/// The stamps of a tenth of a second every few seconds, for the log.
class StampWindow {
public:
    void Note(const void* address, u64 value, bool perf) {
        const auto now = Clock::now();
        std::scoped_lock lock{mutex};
        if (!capturing) {
            if (now < next_window) {
                return;
            }
            capturing = true;
            window_start = now;
            count = 0;
        }
        if (count < entries.size()) {
            entries[count++] = {reinterpret_cast<u64>(address), value,
                                std::chrono::duration<double, std::milli>(now - window_start).count(),
                                perf};
        }
        if (now - window_start >= WindowLength || count == entries.size()) {
            Report();
            capturing = false;
            next_window = now + Every;
        }
    }

    void Mark() {
        std::scoped_lock lock{mutex};
        ++marks;
        LOG_INFO(Lib_GnmDriver,
                 "MARK {}: the player marked this moment (L1 + R1 + R3); the next GPU_STAMPS line "
                 "is what the title's GPU clocks say now",
                 marks);
        if (!capturing) {
            next_window = Clock::now();
        }
    }

private:
    using Clock = std::chrono::steady_clock;
    static constexpr auto WindowLength = std::chrono::milliseconds{100};
    static constexpr auto Every = std::chrono::seconds{3};

    struct Entry {
        u64 address;
        u64 value;
        double host_ms;
        bool perf;
    };

    void Report() {
        if (count == 0) {
            return;
        }
        // For each stamp: where it went (G: the 64-bit clock, P: the performance counter), when
        // the emulator wrote it from the window's start, and how far the clock had moved since
        // the stamp before it of the same clock, in that clock's milliseconds (scaled as the
        // title sees it).
        const double perf_per_ms = static_cast<double>(GpuFrequency()) / 1000.0;
        std::string text;
        u64 last_clock = 0;
        u64 last_perf = 0;
        bool have_clock = false;
        bool have_perf = false;
        for (u32 i = 0; i < count; ++i) {
            const Entry& entry = entries[i];
            double moved = 0.0;
            if (entry.perf) {
                moved = have_perf && perf_per_ms > 0.0
                            ? static_cast<double>(static_cast<s64>(entry.value - last_perf)) / perf_per_ms
                            : 0.0;
                last_perf = entry.value;
                have_perf = true;
            } else {
                moved = have_clock ? static_cast<double>(static_cast<s64>(entry.value - last_clock)) / 1e6 : 0.0;
                last_clock = entry.value;
                have_clock = true;
            }
            text += fmt::format("{}{:x}{} +{:.2f} ({:.2f})", i == 0 ? "" : "; ",
                                entry.address & 0xffffffffffull, entry.perf ? "P" : "G",
                                entry.host_ms, moved);
        }
        LOG_INFO(Lib_GnmDriver,
                 "GPU_STAMPS (scale {:.2f}): {} in {:.0f} ms - address, clock, ms from the first, "
                 "(clock ms since the one before): {}",
                 Scale(), count, entries[count - 1].host_ms, text);
    }

    std::mutex mutex;
    bool capturing{};
    Clock::time_point next_window{};
    Clock::time_point window_start{};
    std::array<Entry, 96> entries{};
    u32 count{};
    u32 marks{};
};

StampWindow& Window() {
    static StampWindow window;
    return window;
}

} // namespace

u64 GpuClock64() {
    return clock64.Get(RawClock64());
}

u64 PerfCounter() {
    return perf_counter.Get(RawPerfCounter());
}

void NoteStamp(const void* address, u64 value, bool perf_counter_stamp) {
    if (!StampLog()) {
        return;
    }
    Window().Note(address, value, perf_counter_stamp);
}

void NoteMark() {
    Window().Mark();
}

} // namespace AmdGpu::GameClock
