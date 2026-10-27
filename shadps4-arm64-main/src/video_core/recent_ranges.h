// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <chrono>
#include <cstddef>

#include "common/types.h"

namespace VideoCore {

/// The last N address ranges a renderer let go of, each with the time it was. A second thread that
/// faults on a page the first one just unprotected finds the watch gone; the range is remembered
/// for a short time only, so an access that faults for another reason cannot be retried for ever.
/// Not thread safe: the caller holds its own lock.
template <size_t N>
class RecentRanges {
public:
    using Clock = std::chrono::steady_clock;

    void Note(u64 start, u64 size, Clock::time_point at) {
        entries[next++ % N] = {start, size, at};
    }

    /// Whether a range overlapping [a, a + n) was noted less than `max_age` before `now`.
    bool Overlaps(u64 a, u64 n, Clock::time_point now, std::chrono::milliseconds max_age) const {
        for (const auto& e : entries) {
            if (e.size && e.start < a + n && e.start + e.size > a && now - e.at < max_age) {
                return true;
            }
        }
        return false;
    }

private:
    struct Entry {
        u64 start = 0;
        u64 size = 0;
        Clock::time_point at{};
    };
    std::array<Entry, N> entries{};
    size_t next = 0;
};

} // namespace VideoCore
