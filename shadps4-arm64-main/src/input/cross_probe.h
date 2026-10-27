// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <chrono>
#include <mutex>
#include <optional>

namespace Input {

/// Measures how long a press or release of Cross takes from the controller's report to the
/// first read of the game that sees it, for a few edges only (the log is for measuring, not
/// for following every press).
class CrossProbe {
public:
    using Clock = std::chrono::steady_clock;

    /// Lines of log a session may use: each edge noted takes two (its own and the game's).
    static constexpr int MaxLines = 20;

    /// The controller reported Cross pressed or released. True when the edge is worth a line of
    /// log, and then the delivery is waited for.
    bool NoteEdge(bool pressed, Clock::time_point now) {
        std::scoped_lock lock{m_mutex};
        if (m_lines + 2 > MaxLines) {
            m_pending = false;
            return false;
        }
        m_lines += 2;
        m_pending = true;
        m_pending_pressed = pressed;
        m_pending_at = now;
        return true;
    }

    /// The game was handed a state with Cross in this position. The delay in ms when that is
    /// the first the game sees of an edge noted before.
    std::optional<double> NoteDelivered(bool pressed, Clock::time_point now) {
        std::scoped_lock lock{m_mutex};
        if (pressed == m_delivered_pressed) {
            return std::nullopt;
        }
        m_delivered_pressed = pressed;
        if (!m_pending || m_pending_pressed != pressed) {
            return std::nullopt;
        }
        m_pending = false;
        return std::chrono::duration<double, std::milli>(now - m_pending_at).count();
    }

private:
    std::mutex m_mutex;
    int m_lines = 0;
    bool m_pending = false;
    bool m_pending_pressed = false;
    Clock::time_point m_pending_at{};
    bool m_delivered_pressed = false;
};

} // namespace Input
