// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <span>

// The count of the writes to the register file that can change the state of a draw (vpps4::DrawState::stateSerial).
// The renderer takes a draw with the same serial as the one it looked at before to have the same fixed state, so every
// write that can change a register a draw's fixed state follows moves it, and when in doubt it moves. Only a write that
// leaves every dword it covers as it was, or changes only the registers named inert (their value is not part of the fixed
// state: the programs' addresses and user data, the geometry), leaves it alone. It holds nothing of the emulator and is
// compiled alone in tools/tests/state_serial_test.cpp. Written by the command processor's thread only.

namespace AmdGpu {

/// The registers [first, last) of the register file.
struct RegRange {
    std::uint32_t first, last;
};

class StateSerial {
public:
    std::uint64_t Value() const noexcept {
        return value;
    }

    /// Something that can change a draw's fixed state was written (or may have been).
    void Bump() noexcept {
        ++value;
    }

    /// `src` goes to the registers `first`... of `file`: the serial moves if one of them that is not inert changes.
    void Write(std::uint32_t* file, std::uint32_t first, const std::uint32_t* src, std::size_t words,
               std::span<const RegRange> inert) noexcept {
        if (words == 0) {
            return;
        }
        bool moved = false;
        for (std::size_t i = 0; i < words && !moved; ++i) {
            if (file[first + i] != src[i]) {
                moved = !IsInert(first + std::uint32_t(i), inert);
            }
        }
        value += moved;
        std::memcpy(file + first, src, words * sizeof(std::uint32_t));
    }

private:
    static bool IsInert(std::uint32_t reg, std::span<const RegRange> inert) noexcept {
        for (const RegRange& r : inert) {
            if (reg >= r.first && reg < r.last) {
                return true;
            }
        }
        return false;
    }

    std::uint64_t value{1};  // (never 0: that is "not known" to the renderer)
};

} // namespace AmdGpu
