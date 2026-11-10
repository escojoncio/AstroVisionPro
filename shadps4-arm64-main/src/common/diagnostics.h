// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdlib>
#include <mutex>
#include <unordered_map>

#include "common/logging/log.h"
#include "common/types.h"

namespace Common {

/// The single diagnostics switch: SHADPS4_DIAGNOSTICS=1 (the app's «Modo diagnóstico»). Off, the
/// diagnostic logs, dumps and test shortcuts do nothing. Read once.
inline bool Diagnostics() {
    static const bool on = [] {
        const char* value = std::getenv("SHADPS4_DIAGNOSTICS");
        const bool enabled = value != nullptr && value[0] == '1' && value[1] == '\0';
        if (enabled) {
            LOG_INFO(Core, "DIAG: diagnostics mode on");
        }
        return enabled;
    }();
    return on;
}

/// Two waits of the GPU path whose wall time the renderer's report tells (VPKENGINE_PROBE
/// CPFRAME): the command processor asleep with nothing to run, and the title's thread held until
/// the GPU is idle. Measured only while diagnostics are on.
enum class DiagWait : u32 { CpIdle, GpuIdle, Count };

namespace Detail {
struct DiagWaitTotal {
    std::atomic<u64> ns{0};
    std::atomic<u64> calls{0};
};
inline DiagWaitTotal& DiagWaitOf(DiagWait wait) {
    static std::array<DiagWaitTotal, static_cast<std::size_t>(DiagWait::Count)> totals;
    return totals[static_cast<std::size_t>(wait)];
}
} // namespace Detail

/// Nanoseconds spent in a wait so far, and how many times it was entered.
inline u64 DiagWaitNs(DiagWait wait) {
    return Detail::DiagWaitOf(wait).ns.load(std::memory_order_relaxed);
}
inline u64 DiagWaitCalls(DiagWait wait) {
    return Detail::DiagWaitOf(wait).calls.load(std::memory_order_relaxed);
}

/// Adds the wall time of its scope to a wait's total.
class DiagWaitScope {
public:
    explicit DiagWaitScope(DiagWait wait_) : wait{wait_}, on{Diagnostics()} {
        if (on) {
            start = std::chrono::steady_clock::now();
        }
    }
    ~DiagWaitScope() {
        if (on) {
            const auto ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
                std::chrono::steady_clock::now() - start);
            Detail::DiagWaitOf(wait).ns.fetch_add(static_cast<u64>(ns.count()),
                                                  std::memory_order_relaxed);
            Detail::DiagWaitOf(wait).calls.fetch_add(1, std::memory_order_relaxed);
        }
    }
    DiagWaitScope(const DiagWaitScope&) = delete;
    DiagWaitScope& operator=(const DiagWaitScope&) = delete;

private:
    const DiagWait wait;
    const bool on;
    std::chrono::steady_clock::time_point start{};
};

namespace Detail {
inline std::atomic<u32>& DiagEpochCounter() {
    static std::atomic<u32> epoch{0};
    return epoch;
}
} // namespace Detail

/// Diagnostic log budgets are counted per epoch; a new epoch (the title entering VR) gives every
/// budget its logs again, so they are not all used up in the menus.
inline u32 DiagEpoch() {
    return Detail::DiagEpochCounter().load(std::memory_order_relaxed);
}

inline void BumpDiagEpoch(const char* why) {
    if (!Diagnostics()) {
        return;
    }
    const u32 epoch = Detail::DiagEpochCounter().fetch_add(1, std::memory_order_relaxed) + 1;
    LOG_INFO(Core, "DIAG: budgets reset ({}), epoch {}", why != nullptr ? why : "", epoch);
}

/// At most `limit` logs per epoch (Take()), or `limit` per key (Take(key), at most kMaxKeys keys
/// per epoch, or as many as given). Always false while diagnostics are off.
class DiagBudget {
public:
    static constexpr std::size_t kMaxKeys = 64;

    explicit DiagBudget(u32 limit_, std::size_t max_keys_ = kMaxKeys)
        : limit{limit_}, max_keys{max_keys_} {}

    bool Take() {
        if (!Diagnostics()) {
            return false;
        }
        std::scoped_lock lock{mutex};
        Refresh();
        if (count >= limit) {
            return false;
        }
        ++count;
        return true;
    }

    bool Take(u64 key) {
        if (!Diagnostics()) {
            return false;
        }
        std::scoped_lock lock{mutex};
        Refresh();
        auto it = per_key.find(key);
        if (it == per_key.end()) {
            if (per_key.size() >= max_keys) {
                return false;
            }
            it = per_key.emplace(key, 0u).first;
        }
        if (it->second >= limit) {
            return false;
        }
        ++it->second;
        return true;
    }

private:
    void Refresh() {
        const u32 now = DiagEpoch();
        if (now != epoch) {
            epoch = now;
            count = 0;
            per_key.clear();
        }
    }

    std::mutex mutex;
    u32 limit;
    std::size_t max_keys;
    u32 epoch = 0;
    u32 count = 0;
    std::unordered_map<u64, u32> per_key;
};

} // namespace Common
