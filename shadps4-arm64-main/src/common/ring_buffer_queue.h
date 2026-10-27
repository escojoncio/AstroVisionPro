// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <algorithm>
#include <optional>
#include <vector>
#include "common/types.h"

template <class T>
class RingBufferQueue {
public:
    RingBufferQueue(u64 size) : m_storage(size) {}

    void Push(T item) {
        const u64 index = (m_begin + m_size) % m_storage.size();
        m_storage[index] = std::move(item);
        if (m_size < m_storage.size()) {
            m_size += 1;
        } else {
            m_begin = (m_begin + 1) % m_storage.size();
        }
    }

    std::optional<T> Pop() {
        if (m_size == 0) {
            return {};
        }
        const u64 index = m_begin;
        m_begin = (m_begin + 1) % m_storage.size();
        m_size -= 1;
        return std::move(m_storage[index]);
    }

    std::optional<T> Peek() {
        if (m_size == 0) {
            return {};
        }
        return m_storage[m_begin];
    }

    /// The newest item, to be changed in place; null when the queue is empty.
    T* Newest() {
        if (m_size == 0) {
            return nullptr;
        }
        return &m_storage[(m_begin + m_size - 1) % m_storage.size()];
    }

    /// Takes the newest `max` items (fewer if there are fewer) in the order they were pushed, and
    /// empties the queue: whatever is older than those is dropped. Returns how many were taken.
    u64 DrainNewest(T* out, u64 max) {
        const u64 count = std::min<u64>(max, m_size);
        const u64 skipped = m_size - count;
        for (u64 i = 0; i < count; ++i) {
            out[i] = std::move(m_storage[(m_begin + skipped + i) % m_storage.size()]);
        }
        m_begin = 0;
        m_size = 0;
        return count;
    }

private:
    u64 m_begin = 0;
    u64 m_size = 0;
    std::vector<T> m_storage;
};