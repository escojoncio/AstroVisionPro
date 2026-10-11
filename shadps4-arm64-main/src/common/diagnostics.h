// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <atomic>
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
