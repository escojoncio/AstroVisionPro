// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>

namespace Common::JitArena {

/// Memory the emulator writes ARM64 code into and runs it from, on systems that only hand out
/// such memory once, as two mappings of the same pages: one that can be executed and one that
/// can be written (visionOS, see platform/visionos/jit_arena.c). Elsewhere there is none, and
/// code memory is made the usual way (mmap and mprotect).
struct Block {
    std::uint8_t* rx{}; ///< Where the code runs.
    std::uint8_t* rw{}; ///< Where it is written.
    std::size_t size{};

    explicit operator bool() const {
        return size != 0;
    }
};

/// Whether there is such memory.
bool Available();

/// `size` bytes of it (rounded up to whole pages), or nothing when it ran out. Thread safe.
std::optional<Block> Allocate(std::size_t size);
/// Gives back what Allocate handed out, by its executable address.
void Free(const void* rx);

/// How far the writable mapping is from the executable one: writable = executable + offset.
std::ptrdiff_t WriteOffset();
/// Whether an address is in the executable mapping.
bool Contains(const void* address);
/// The writable address for an executable one in the arena (or the address itself otherwise).
template <typename T>
T* Writable(T* address) {
    return Contains(address)
               ? reinterpret_cast<T*>(reinterpret_cast<std::uintptr_t>(address) + WriteOffset())
               : address;
}

/// Makes the instruction cache see code written through the writable mapping.
void FlushInstructionCache(const void* rx, std::size_t size);

} // namespace Common::JitArena
