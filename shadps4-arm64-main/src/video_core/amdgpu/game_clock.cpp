// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <array>
#include <atomic>
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

/// The least the automatic clocks are slowed to (a tenth of real time).
constexpr double MinFactor = 0.1;
/// Without a frame's end for this long (a load, a hang), the automatic clocks are put back
/// on real time at the next stamp instead.
constexpr s64 LateAfterNs = 1'000'000'000;

/// What SHADPS4_GPU_CLOCK_SCALE asks for: a fixed fraction (0.1 to 1), or "auto" (0 here).
double Setting() {
    static const double setting = [] {
        const char* value = std::getenv("SHADPS4_GPU_CLOCK_SCALE");
        if (value != nullptr && (value[0] == 'a' || value[0] == 'A')) {
            LOG_INFO(Lib_GnmDriver,
                     "GPU_CLOCK: automatic - the title's GPU clocks run slower within each frame, "
                     "by as much as keeps what it measures with them within a console's budget, "
                     "and are put back on real time at the end of every frame");
            return 0.0;
        }
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
    return setting;
}

bool Automatic() {
    return Setting() == 0.0;
}

/// The factor the automatic clocks run at now (written by SetFactor, read by every stamp).
std::atomic<double> auto_factor{1.0};

/// The scale the stamp log shows.
double Scale() {
    return Automatic() ? auto_factor.load(std::memory_order_relaxed) : Setting();
}

bool StampLog() {
    static const bool on = [] {
        const char* value = std::getenv("SHADPS4_GPU_STAMP_LOG");
        return value != nullptr && value[0] == '1';
    }();
    return on;
}

/// A clock that runs at a fraction of the raw one. Fixed: from its first reading on, drifting
/// away from real time. Automatic: at the factor in auto_factor, re-anchored (continuing from
/// where it was) when the factor changes, and put back on the raw clock by Resync at the end
/// of every frame, so that it never drifts more than one frame's worth. Never goes back.
class Scaled {
public:
    u64 Get(u64 raw) {
        if (!Automatic()) {
            const double scale = Setting();
            if (scale == 1.0) {
                return raw;
            }
            std::call_once(once, [&] { anchor = raw; });
            if (raw >= anchor) {
                return anchor + static_cast<u64>(static_cast<double>(raw - anchor) * scale);
            }
            return anchor - static_cast<u64>(static_cast<double>(anchor - raw) * scale);
        }
        std::scoped_lock lock{mutex};
        if (!started) {
            started = true;
            raw_anchor = raw;
            value_anchor = raw;
            factor_used = auto_factor.load(std::memory_order_relaxed);
        }
        const double factor = auto_factor.load(std::memory_order_relaxed);
        if (factor != factor_used) {
            value_anchor = std::max(last, Value(raw));
            raw_anchor = std::max(raw, raw_anchor);
            factor_used = factor;
        }
        last = std::max(last, Value(raw));
        return last;
    }

    /// Back on the raw clock (never behind what was given out). Returns by how much it moved
    /// forward beyond its own pace, in raw units.
    u64 Resync(u64 raw) {
        std::scoped_lock lock{mutex};
        if (!started) {
            return 0;
        }
        const u64 now = std::max(last, Value(raw));
        const u64 target = std::max(now, raw);
        raw_anchor = std::max(raw, raw_anchor);
        value_anchor = target;
        last = target;
        return target - now;
    }

private:
    u64 Value(u64 raw) const {
        if (raw <= raw_anchor) {
            return value_anchor;
        }
        return value_anchor +
               static_cast<u64>(static_cast<double>(raw - raw_anchor) * factor_used);
    }

    std::once_flag once;
    u64 anchor{};

    std::mutex mutex;
    bool started{};
    u64 raw_anchor{};
    u64 value_anchor{};
    u64 last{};
    double factor_used{1.0};
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
    ResyncIfLate();
    return clock64.Get(RawClock64());
}

u64 PerfCounter() {
    ResyncIfLate();
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

bool IsAutomatic() {
    return Automatic();
}

void SetFactor(double factor) {
    auto_factor.store(std::clamp(factor, MinFactor, 1.0), std::memory_order_relaxed);
}

double Factor() {
    return Automatic() ? auto_factor.load(std::memory_order_relaxed) : Setting();
}

namespace {
std::atomic<u64> frame_resyncs{0};
std::atomic<u64> late_resyncs{0};
std::atomic<u64> catch_up_ns{0};
std::atomic<s64> last_resync_ns{0};

s64 SteadyNs() {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

std::atomic<u64> perf_catch_up_ns{0};

void DoResync() {
    const u64 moved = clock64.Resync(RawClock64());
    const u64 perf_moved = perf_counter.Resync(RawPerfCounter());
    catch_up_ns.fetch_add(moved, std::memory_order_relaxed);
    if (const u64 frequency = GpuFrequency(); frequency != 0) {
        perf_catch_up_ns.fetch_add(Common::MultiplyAndDivide64(perf_moved, 1'000'000'000, frequency),
                                   std::memory_order_relaxed);
    }
    last_resync_ns.store(SteadyNs(), std::memory_order_relaxed);
}
} // namespace

void OnFrameDone() {
    if (!Automatic()) {
        return;
    }
    DoResync();
    frame_resyncs.fetch_add(1, std::memory_order_relaxed);
}

void ResyncIfLate() {
    if (!Automatic()) {
        return;
    }
    const s64 last = last_resync_ns.load(std::memory_order_relaxed);
    if (last != 0 && SteadyNs() - last < LateAfterNs) {
        return;
    }
    if (last == 0) {
        last_resync_ns.store(SteadyNs(), std::memory_order_relaxed);
        return;
    }
    DoResync();
    late_resyncs.fetch_add(1, std::memory_order_relaxed);
}

ResyncStats TakeResyncStats() {
    ResyncStats stats;
    stats.frames = frame_resyncs.exchange(0, std::memory_order_relaxed);
    stats.late = late_resyncs.exchange(0, std::memory_order_relaxed);
    // Titles read one clock or the other: the one that moved more is the one read.
    const u64 clock_ns = catch_up_ns.exchange(0, std::memory_order_relaxed);
    const u64 perf_ns = perf_catch_up_ns.exchange(0, std::memory_order_relaxed);
    stats.catch_up_ms = static_cast<double>(std::max(clock_ns, perf_ns)) / 1e6;
    return stats;
}

} // namespace AmdGpu::GameClock
