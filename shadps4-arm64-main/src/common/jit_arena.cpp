// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#include <algorithm>
#include <iterator>
#include <map>
#include <mutex>

#include "common/jit_arena.h"

#if defined(SHADPS4_VISIONOS)
#include <libkern/OSCacheControl.h>
#include <mach/vm_page_size.h>
#include "platform/visionos/astro_core.h"
#endif

namespace Common::JitArena {

namespace {

struct Arena {
    std::mutex mutex;
    bool initialized{};
    std::uintptr_t rx{};
    std::uintptr_t rw{};
    std::size_t size{};
    std::size_t page{16384};
    /// Free ranges by their offset into the arena, with their size. Neighbours are merged.
    std::map<std::size_t, std::size_t> free_ranges;
    /// What was handed out, by offset, with its size.
    std::map<std::size_t, std::size_t> used;
    /// Bytes handed out now, and the most there ever were at once.
    std::size_t used_bytes{};
    std::size_t most_bytes{};

    void Initialize() {
        if (initialized) {
            return;
        }
        initialized = true;
#if defined(SHADPS4_VISIONOS)
        AstroJitArena arena{};
        if (astro_jit_get_arena(&arena) && arena.size != 0) {
            rx = arena.rx;
            rw = arena.rw;
            size = arena.size;
            page = vm_page_size;
            free_ranges.emplace(0, size);
        }
#endif
    }
};

Arena& Instance() {
    static Arena arena;
    return arena;
}

} // namespace

std::pair<std::uintptr_t, std::uintptr_t> Range() {
    Arena& arena = Instance();
    std::scoped_lock lock{arena.mutex};
    arena.Initialize();
    return {arena.rx, arena.rx + arena.size};
}

bool Available() {
    Arena& arena = Instance();
    std::scoped_lock lock{arena.mutex};
    arena.Initialize();
    return arena.size != 0;
}

std::optional<Block> Allocate(std::size_t size) {
    Arena& arena = Instance();
    std::scoped_lock lock{arena.mutex};
    arena.Initialize();
    if (arena.size == 0 || size == 0) {
        return std::nullopt;
    }
    size = (size + arena.page - 1) & ~(arena.page - 1);
    // First fit: code is allocated rarely and in few sizes.
    for (auto it = arena.free_ranges.begin(); it != arena.free_ranges.end(); ++it) {
        if (it->second < size) {
            continue;
        }
        const std::size_t offset = it->first;
        const std::size_t left = it->second - size;
        arena.free_ranges.erase(it);
        if (left != 0) {
            arena.free_ranges.emplace(offset + size, left);
        }
        arena.used.emplace(offset, size);
        arena.used_bytes += size;
        arena.most_bytes = std::max(arena.most_bytes, arena.used_bytes);
        return Block{
            .rx = reinterpret_cast<std::uint8_t*>(arena.rx + offset),
            .rw = reinterpret_cast<std::uint8_t*>(arena.rw + offset),
            .size = size,
        };
    }
    return std::nullopt;
}

void Free(const void* rx) {
    Arena& arena = Instance();
    std::scoped_lock lock{arena.mutex};
    const auto address = reinterpret_cast<std::uintptr_t>(rx);
    if (arena.size == 0 || address < arena.rx || address >= arena.rx + arena.size) {
        return;
    }
    const std::size_t offset = address - arena.rx;
    const auto used = arena.used.find(offset);
    if (used == arena.used.end()) {
        return;
    }
    std::size_t begin = offset;
    std::size_t length = used->second;
    arena.used.erase(used);
    arena.used_bytes -= length;
    // Merge with the free ranges on either side.
    auto next = arena.free_ranges.lower_bound(begin);
    if (next != arena.free_ranges.end() && next->first == begin + length) {
        length += next->second;
        next = arena.free_ranges.erase(next);
    }
    if (next != arena.free_ranges.begin()) {
        auto previous = std::prev(next);
        if (previous->first + previous->second == begin) {
            begin = previous->first;
            length += previous->second;
            arena.free_ranges.erase(previous);
        }
    }
    arena.free_ranges.emplace(begin, length);
}

Usage GetUsage() {
    Arena& arena = Instance();
    std::scoped_lock lock{arena.mutex};
    return {arena.rx, arena.used_bytes, arena.most_bytes, arena.size};
}

std::ptrdiff_t WriteOffset() {
    Arena& arena = Instance();
    // (Fixed once the arena exists, and only read after it was handed out.)
    return static_cast<std::ptrdiff_t>(arena.rw) - static_cast<std::ptrdiff_t>(arena.rx);
}

bool Contains(const void* address) {
    const Arena& arena = Instance();
    const auto value = reinterpret_cast<std::uintptr_t>(address);
    return arena.size != 0 && value >= arena.rx && value < arena.rx + arena.size;
}

void FlushInstructionCache(const void* rx, std::size_t size) {
#if defined(SHADPS4_VISIONOS)
    sys_icache_invalidate(const_cast<void*>(rx), size);
#else
    __builtin___clear_cache(static_cast<char*>(const_cast<void*>(rx)),
                            static_cast<char*>(const_cast<void*>(rx)) + size);
#endif
}

} // namespace Common::JitArena
