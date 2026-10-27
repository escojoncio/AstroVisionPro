// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <chrono>
#include <vector>

#include <gtest/gtest.h>

#include "common/ring_buffer_queue.h"
#include "input/cross_probe.h"

namespace {

using std::chrono::milliseconds;

std::vector<int> Drain(RingBufferQueue<int>& queue, u64 max) {
    std::vector<int> out(64);
    out.resize(queue.DrainNewest(out.data(), max));
    return out;
}

TEST(PadQueue, OneStateIsTheNewestAndEmptiesTheQueue) {
    RingBufferQueue<int> queue(64);
    for (int i = 1; i <= 10; ++i) {
        queue.Push(i);
    }
    EXPECT_EQ(Drain(queue, 1), std::vector<int>{10});
    EXPECT_TRUE(Drain(queue, 1).empty());
}

TEST(PadQueue, SeveralStatesAreTheNewestInOrder) {
    RingBufferQueue<int> queue(64);
    for (int i = 1; i <= 10; ++i) {
        queue.Push(i);
    }
    EXPECT_EQ(Drain(queue, 3), (std::vector<int>{8, 9, 10}));
    EXPECT_TRUE(Drain(queue, 3).empty());
}

TEST(PadQueue, FewerStatesThanAskedForAreAllGiven) {
    RingBufferQueue<int> queue(64);
    queue.Push(1);
    queue.Push(2);
    EXPECT_EQ(Drain(queue, 8), (std::vector<int>{1, 2}));
}

TEST(PadQueue, AFullQueueThatWrappedKeepsItsOrder) {
    RingBufferQueue<int> queue(64);
    for (int i = 1; i <= 100; ++i) {
        queue.Push(i);
    }
    EXPECT_EQ(Drain(queue, 1), std::vector<int>{100});
    for (int i = 1; i <= 100; ++i) {
        queue.Push(i);
    }
    const auto all = Drain(queue, 64);
    ASSERT_EQ(all.size(), 64u);
    EXPECT_EQ(all.front(), 37);
    EXPECT_EQ(all.back(), 100);
}

TEST(PadQueue, TheQueueWorksAfterBeingDrained) {
    RingBufferQueue<int> queue(4);
    for (int i = 1; i <= 6; ++i) {
        queue.Push(i);
    }
    EXPECT_EQ(Drain(queue, 2), (std::vector<int>{5, 6}));
    queue.Push(7);
    queue.Push(8);
    EXPECT_EQ(Drain(queue, 4), (std::vector<int>{7, 8}));
}

TEST(PadQueue, NewestCanBeBroughtUpToDate) {
    RingBufferQueue<int> queue(4);
    EXPECT_EQ(queue.Newest(), nullptr);
    queue.Push(1);
    queue.Push(2);
    *queue.Newest() = 20;
    EXPECT_EQ(Drain(queue, 4), (std::vector<int>{1, 20}));
}

TEST(CrossProbe, TheDelayIsMeasuredFromTheEdgeToItsFirstDelivery) {
    Input::CrossProbe probe;
    const auto t0 = Input::CrossProbe::Clock::now();
    EXPECT_TRUE(probe.NoteEdge(true, t0));
    const auto delay = probe.NoteDelivered(true, t0 + milliseconds(480));
    ASSERT_TRUE(delay.has_value());
    EXPECT_NEAR(*delay, 480.0, 0.01);
    // The same position again is no new edge for the game.
    EXPECT_FALSE(probe.NoteDelivered(true, t0 + milliseconds(500)).has_value());
}

TEST(CrossProbe, AnEdgeTheGameNeverSawIsNotReported) {
    Input::CrossProbe probe;
    const auto t0 = Input::CrossProbe::Clock::now();
    EXPECT_TRUE(probe.NoteEdge(true, t0));
    EXPECT_TRUE(probe.NoteEdge(false, t0 + milliseconds(50)));
    // Pressed and released between two reads: the game sees released twice.
    EXPECT_FALSE(probe.NoteDelivered(false, t0 + milliseconds(100)).has_value());
}

TEST(CrossProbe, ReleaseIsReportedAfterPress) {
    Input::CrossProbe probe;
    const auto t0 = Input::CrossProbe::Clock::now();
    probe.NoteEdge(true, t0);
    ASSERT_TRUE(probe.NoteDelivered(true, t0 + milliseconds(10)).has_value());
    probe.NoteEdge(false, t0 + milliseconds(200));
    const auto delay = probe.NoteDelivered(false, t0 + milliseconds(260));
    ASSERT_TRUE(delay.has_value());
    EXPECT_NEAR(*delay, 60.0, 0.01);
}

TEST(CrossProbe, AtMostTwentyLinesPerSession) {
    Input::CrossProbe probe;
    const auto t0 = Input::CrossProbe::Clock::now();
    int lines = 0;
    bool pressed = true;
    for (int i = 0; i < 100; ++i, pressed = !pressed) {
        if (probe.NoteEdge(pressed, t0)) {
            ++lines;
            if (probe.NoteDelivered(pressed, t0 + milliseconds(1))) {
                ++lines;
            }
        }
    }
    EXPECT_EQ(lines, Input::CrossProbe::MaxLines);
}

} // namespace
