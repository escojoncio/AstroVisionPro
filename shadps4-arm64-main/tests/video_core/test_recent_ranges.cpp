// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <chrono>

#include <gtest/gtest.h>

#include "video_core/recent_ranges.h"

namespace {

using namespace std::chrono_literals;
using Clock = std::chrono::steady_clock;
using VideoCore::RecentRanges;

TEST(RecentRanges, OverlapFindsOnlyFreshRanges) {
    RecentRanges<4> ranges;
    const auto t0 = Clock::now();
    ranges.Note(0x4fbd00, 4, t0);
    EXPECT_TRUE(ranges.Overlaps(0x4fbd00, 8, t0 + 199ms, 200ms));
    EXPECT_FALSE(ranges.Overlaps(0x4fbd00, 8, t0 + 200ms, 200ms));
    // A range let go of long ago no longer makes an access "handled" (it would be retried for ever).
    EXPECT_FALSE(ranges.Overlaps(0x4fbd00, 8, t0 + 5s, 200ms));
}

TEST(RecentRanges, OverlapIsByRangeNotByPoint) {
    RecentRanges<4> ranges;
    const auto t0 = Clock::now();
    ranges.Note(0x4fbd00, 4, t0);
    EXPECT_TRUE(ranges.Overlaps(0x4fb000, 0x1000, t0, 200ms));   // the 4 KB piece around it
    EXPECT_FALSE(ranges.Overlaps(0x4fb000, 0xd00, t0, 200ms));   // ends where it starts
    EXPECT_FALSE(ranges.Overlaps(0x4fbd04, 8, t0, 200ms));       // starts where it ends
}

TEST(RecentRanges, OldestEntryIsReplacedWhenFull) {
    RecentRanges<2> ranges;
    const auto t0 = Clock::now();
    ranges.Note(0x1000, 0x10, t0);
    ranges.Note(0x2000, 0x10, t0);
    ranges.Note(0x3000, 0x10, t0);
    EXPECT_FALSE(ranges.Overlaps(0x1000, 0x10, t0, 200ms));
    EXPECT_TRUE(ranges.Overlaps(0x2000, 0x10, t0, 200ms));
    EXPECT_TRUE(ranges.Overlaps(0x3000, 0x10, t0, 200ms));
}

TEST(RecentRanges, EmptyRangeIsNeverFound) {
    RecentRanges<2> ranges;
    const auto t0 = Clock::now();
    ranges.Note(0x1000, 0, t0);
    EXPECT_FALSE(ranges.Overlaps(0x0, 0x2000, t0, 200ms));
}

} // namespace
