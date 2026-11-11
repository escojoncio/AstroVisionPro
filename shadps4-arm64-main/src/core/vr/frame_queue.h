// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

// Which frame of the title the headset takes next, and which finished ones are given up. It holds
// nothing of the emulator and is compiled alone in tools/tests/frame_queue_test.cpp. Callers lock.

namespace Core::Vr {

enum class SlotState { Free, Drawing, Ready, Reading };

/// A finished frame waits to be taken; of the finished ones, the `Depth` newest are kept and the
/// oldest of those is taken first, so that two deliveries between two takes are both shown (the
/// headset takes about as many frames as the title delivers, but not at the same instants). Older
/// ones are given up for the next frame to be drawn into. `take_latest`: only the newest is kept
/// and taken, a delivery that was not taken in time is lost.
template <std::size_t N>
class FrameQueue {
public:
    static constexpr std::size_t Depth = 2;

    bool take_latest{false};
    /// Frames finished and then given up without being taken.
    std::uint32_t superseded{};

    SlotState State(std::size_t slot) const {
        return state[slot];
    }

    /// Whether `slot` can be drawn into: free, or finished and given up: older than the
    /// last one taken, or not among the `Depth` newest.
    bool Reusable(std::size_t slot) const {
        if (state[slot] == SlotState::Free) {
            return true;
        }
        if (state[slot] != SlotState::Ready) {
            return false;
        }
        if (take_latest) {
            return static_cast<int>(slot) != latest;
        }
        if (sequence[slot] < taken) {
            return true; // older than what was taken: it can no longer be shown in order
        }
        std::size_t newer = 0;
        for (std::size_t other = 0; other < N; ++other) {
            newer += state[other] == SlotState::Ready && sequence[other] > sequence[slot];
        }
        return newer >= Depth;
    }

    /// Starts drawing into `slot`, which has to be Reusable.
    void Begin(std::size_t slot) {
        superseded += state[slot] == SlotState::Ready;
        state[slot] = SlotState::Drawing;
    }

    /// The frame in `slot` is finished. False: it was not being drawn.
    bool End(std::size_t slot) {
        if (state[slot] != SlotState::Drawing) {
            return false;
        }
        state[slot] = SlotState::Ready;
        sequence[slot] = ++counter;
        latest = static_cast<int>(slot);
        return true;
    }

    /// The frame in `slot` will not be delivered.
    void Drop(std::size_t slot) {
        if (state[slot] == SlotState::Drawing) {
            state[slot] = SlotState::Free;
        }
    }

    /// The slot of the frame to show next, now being read; -1: none waits.
    int Take() {
        int pick = -1;
        if (take_latest) {
            if (latest >= 0 && state[latest] == SlotState::Ready) {
                pick = latest;
            }
        } else {
            // The oldest of the Depth newest finished frames.
            std::size_t kept = 0;
            for (std::size_t slot = 0; slot < N; ++slot) {
                if (state[slot] == SlotState::Ready && !Reusable(slot)) {
                    ++kept;
                    if (pick < 0 || sequence[slot] < sequence[pick]) {
                        pick = static_cast<int>(slot);
                    }
                }
            }
            if (kept == 0) {
                return -1;
            }
        }
        if (pick >= 0) {
            state[pick] = SlotState::Reading;
            taken = sequence[pick];
        }
        return pick;
    }

    /// The headset is done with `slot` (or it was taken and not shown after all).
    void Return(std::size_t slot) {
        if (state[slot] == SlotState::Reading) {
            state[slot] = SlotState::Free;
        }
    }

private:
    std::array<SlotState, N> state{};
    std::array<std::uint64_t, N> sequence{};
    std::uint64_t counter{};
    std::uint64_t taken{}; // the sequence of the last frame taken
    int latest{-1};
};

} // namespace Core::Vr
