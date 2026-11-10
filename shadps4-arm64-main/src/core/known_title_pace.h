// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>

/// What decides how many refreshes of the headset a frame of the title is given, as plain
/// numbers (nothing of the emulator in here, so that it can be tried alone:
/// tools/tests/known_title_pace_test.cpp).
///
/// The plan is quantized to the panel. A frame is given a whole number of refreshes: the base
/// pace is the fewest that keep it to 60 a second or less (100 Hz: 2, which is 50 a second;
/// 90 Hz: 2, 45; 120 Hz: 2, 60), the fallback is one refresh more where that still makes about
/// 30 a second (100 Hz: 3, 33.3; 90 Hz: 3, 30; 120 Hz: 3, 40), and where it does not there is
/// no fallback (72 Hz). Never faster than the base, never slower than the fallback.
namespace Core::KnownTitle::Pacing {

enum class Mode {
    Auto,   ///< Starts at the fallback and goes to the base when it holds, back when it fails.
    Base,   ///< Always the base.
    Steady, ///< Always the fallback (the base where there is none).
};

struct Plan {
    double panel{}; ///< Hz.
    int base{};     ///< Refreshes a frame at the base pace.
    int fallback{}; ///< Refreshes a frame at the fallback pace, 0 for none.

    double BaseFps() const {
        return base != 0 ? panel / base : 0.0;
    }
    double FallbackFps() const {
        return fallback != 0 ? panel / fallback : 0.0;
    }
};

/// The plan for a panel of `panel` Hz (a rate that cannot be one is taken for 120).
inline Plan MakePlan(double panel) {
    if (!(panel > 20.0)) {
        panel = 120.0;
    }
    const int div = std::max(1, static_cast<int>(std::ceil(panel / 60.0 - 0.05)));
    Plan plan{.panel = panel, .base = div, .fallback = 0};
    if (panel / (div + 1) >= 29.5) {
        plan.fallback = div + 1;
    }
    return plan;
}

/// How long the GPU worked on a frame of a window, for Regulator::Gpu. `busy` is the time the
/// GPU's command buffers ran during the window's `span` seconds, where the renderer has that
/// figure (below zero where it has none): that share of the `taken` seconds a frame took.
/// Without it, `in_flight`: the share of the looks that found a frame handed to the GPU and not
/// finished, of a frame's time, which counts the time a frame waits behind the one before as
/// work (measured on a headset: 4 to 6 ms over, enough to never leave the fallback).
inline double GpuFrameTime(double busy, double span, double taken, double in_flight) {
    if (busy >= 0.0 && span > 0.0) {
        return std::min(busy / span, 1.0) * taken;
    }
    return in_flight;
}

/// The command thread's share of a frame, for FrameWorkTime: `cp` seconds of processor time
/// during the window's `span` seconds, of the `taken` seconds a frame took. Below zero where
/// `cp` is not told (below zero) or the window has no length.
inline double CpFrameTime(double cp, double span, double taken) {
    if (cp >= 0.0 && span > 0.0) {
        return std::min(cp / span, 1.0) * taken;
    }
    return -1.0;
}

/// What Regulator::Gpu is told a frame took: `gpu` (GpuFrameTime), or what the thread that turns
/// the title's commands into the renderer's used of a processor for it, where that is told and
/// is more (`cp` seconds of processor time during the window's `span` seconds, below zero where
/// it is not told; `taken` seconds a frame). A frame that thread cannot make within the base
/// pace misses its refresh however idle the GPU is: going back to the base would fail at once.
inline double FrameWorkTime(double gpu, double cp, double span, double taken) {
    return std::max(gpu, CpFrameTime(cp, span, taken));
}

/// The two figures a frame's time is the more of (GpuFrameTime and CpFrameTime), per frame and
/// in seconds, and which of them was the more: the one the regulator went by. `cp` is below
/// zero where the renderer does not tell it. For the logs; the regulator's rule does not look at it.
struct Figures {
    double gpu{};
    double cp{-1.0};
    bool by_cp{}; ///< The command thread's figure was the more.
};

/// "GPU" or "command thread": the figure that decided.
inline const char* DecidedBy(const Figures& figures) {
    return figures.by_cp ? "command thread" : "GPU";
}

/// Both figures in a line, e.g. "GPU 22.0 ms, command thread 18.1 ms".
inline std::string FiguresText(const Figures& figures) {
    char text[96];
    if (figures.cp >= 0.0) {
        std::snprintf(text, sizeof text, "GPU %.1f ms, command thread %.1f ms", figures.gpu * 1e3,
                      figures.cp * 1e3);
    } else {
        std::snprintf(text, sizeof text, "GPU %.1f ms, command thread not told", figures.gpu * 1e3);
    }
    return text;
}

/// Chooses between the base and the fallback pace of a plan from the frames' intervals and
/// from how long the GPU worked on them. All times are in seconds, on any clock that does not
/// go back.
///
/// Measured on a headset (the thresholds are not arbitrary):
///  - A frame delivered more than 1.25 periods of the pace after the one before missed its
///    refresh, whatever the cause (the GPU may be idle in between: ordering, the CPU).
///    Intervals past 3 periods (streaming, shader builds) and past 250 ms (loads) say nothing
///    about the pace and do not count.
///  - At the base, 0.3 s that hold 10 frames with over a quarter of them late leave the base
///    at once: pictures alternating two and three refreshes read as fewer frames a second than
///    either pace. Slower ways out: a second with over 15% late, or two seconds in a row with
///    the GPU over 95% of the base period.
///  - The way back takes `need` seconds in a row with the GPU under 92% of the BASE period and
///    at most 5% of the frames late (for the fallback period; one is always allowed), so that a
///    quiet second between two heavy ones does not flip the pace. A base that fails within 20 s
///    of coming back doubles `need` (10 to 120 s at most); one that held 60 s resets it.
class Regulator {
public:
    enum class Why {
        Start,  ///< Began at the fallback (the GPU time is known).
        Burst,  ///< Over a quarter of 10 or more frames in 0.3 s late.
        Missed, ///< Over 15% of the frames of a second late.
        Heavy,  ///< Two seconds in a row with the GPU over 95% of the base period.
        Good,   ///< `need` seconds in a row of good seconds.
    };

    /// The switch the last `Frame` that answered true made, and the figures that decided it:
    /// the window it was decided on (seconds `span`, `frames` counted, `late` of them late,
    /// the GPU `gpu` seconds a frame) and the `need` that now stands.
    struct Switch {
        Why why{};
        bool to_fallback{};
        double gpu{};
        int late{};
        int frames{};
        double span{};
        double need{};
        Figures figures{}; ///< The two figures `gpu` is the more of, over the window.
    };

    /// The last window closed (to tell once a minute what is seen).
    struct Seen {
        double gpu{};
        int late{};
        int frames{};
        Figures figures{}; ///< The two figures `gpu` is the more of, over the window.
    };

    explicit Regulator(Mode mode_) : mode{mode_}, plan{MakePlan(120.0)} {}

    /// A plan other than the one before (the panel turned out to be another rate).
    void SetPlan(const Plan& next) {
        plan = next;
        if (plan.fallback == 0) {
            started = false;
            at_fallback = false;
        }
    }

    /// The GPU worked `per_frame` seconds on each of `frames` frames (nothing to say when it
    /// could not be told: the regulator does not start before it is told once).
    void Gpu(double per_frame, int frames) {
        if (frames <= 0) {
            return;
        }
        gpu_sum += per_frame * frames;
        gpu_frames += frames;
        measured = true;
    }

    /// The same, with the two figures `per_frame` is the more of (for the logs: nothing else
    /// changes).
    void Gpu(double per_frame, int frames, const Figures& parts) {
        if (frames <= 0) {
            return;
        }
        Gpu(per_frame, frames);
        parts_gpu_sum += parts.gpu * frames;
        parts_frames += frames;
        if (parts.cp >= 0.0) {
            parts_cp_sum += parts.cp * frames;
            parts_cp_frames += frames;
        }
    }

    /// A frame arrived at `now`, `interval` after the one before. True when the pace changed.
    bool Frame(double now, double interval) {
        if (mode != Mode::Auto || plan.fallback == 0 || !measured) {
            return false;
        }
        if (!started) {
            started = true;
            at_fallback = true;
            base_since = -1.0;
            good = 0.0;
            over = 0;
            ClearWindow(now);
            last = {.why = Why::Start, .to_fallback = true, .need = need};
            return true;
        }
        const double period = (at_fallback ? plan.fallback : plan.base) / plan.panel;
        if (interval > 0.0 && interval < Stall) {
            ++frames;
            if (interval > 1.25 * period && interval < 3.0 * period) {
                ++late;
            }
        }
        const double span = now - window_start;
        const bool burst = !at_fallback && span >= 0.3 && frames >= 10 && late > 0.25 * frames;
        if (!burst && span < 1.0) {
            return false;
        }
        const int gpu_n = gpu_frames;
        const double avg = gpu_n != 0 ? gpu_sum / gpu_n : 0.0;
        const int counted = frames;
        const int slow = late;
        const Figures figures = WindowFigures(avg);
        seen = {avg, slow, counted, figures};
        ClearWindow(now);

        const double base_period = plan.base / plan.panel;
        if (!at_fallback && base_since >= 0.0 && now - base_since >= 60.0) {
            need = 10.0;
        }
        bool to_fallback = false;
        bool to_base = false;
        Why why = Why::Good;
        if (burst) {
            to_fallback = true;
            why = Why::Burst;
        } else if (at_fallback) {
            if (gpu_n == 0) {
                return false; // Nothing was measured: no second to count.
            }
            const double allowed = std::max(1.0, 0.05 * counted);
            good = avg < 0.92 * base_period && slow <= allowed ? good + span : 0.0;
            to_base = good >= need;
        } else if (counted >= 10 && slow > 0.15 * counted) {
            to_fallback = true;
            why = Why::Missed;
        } else if (gpu_n != 0) {
            over = avg > 0.95 * base_period ? over + 1 : 0;
            if (over >= 2) {
                to_fallback = true;
                why = Why::Heavy;
            }
        }
        if (!to_fallback && !to_base) {
            return false;
        }
        if (to_fallback) {
            // A base that failed soon after it came back: the next try waits longer.
            if (base_since >= 0.0 && now - base_since < 20.0) {
                need = std::min(need * 2.0, 120.0);
            }
            base_since = -1.0;
        } else {
            base_since = now;
        }
        at_fallback = to_fallback;
        over = 0;
        good = 0.0;
        last = {why, to_fallback, avg, slow, counted, span, need, figures};
        return true;
    }

    /// Refreshes a frame is given.
    int Pace() const {
        if (mode == Mode::Base || plan.fallback == 0) {
            return plan.base;
        }
        if (mode == Mode::Steady) {
            return plan.fallback;
        }
        return at_fallback ? plan.fallback : plan.base;
    }

    bool AtFallback() const {
        return plan.fallback != 0 && Pace() == plan.fallback;
    }
    const Plan& GetPlan() const {
        return plan;
    }
    const Switch& Last() const {
        return last;
    }
    const Seen& Window() const {
        return seen;
    }
    /// Seconds in a row of good frames that the way back to the base asks for now.
    double Need() const {
        return need;
    }

private:
    /// The two figures of the window being closed (`avg` for the GPU's where none was told).
    Figures WindowFigures(double avg) const {
        Figures figures{.gpu = avg};
        if (parts_frames != 0) {
            figures.gpu = parts_gpu_sum / parts_frames;
        }
        if (parts_cp_frames != 0) {
            figures.cp = parts_cp_sum / parts_cp_frames;
            figures.by_cp = figures.cp > figures.gpu;
        }
        return figures;
    }

    void ClearWindow(double now) {
        window_start = now;
        parts_gpu_sum = 0.0;
        parts_cp_sum = 0.0;
        parts_frames = 0;
        parts_cp_frames = 0;
        gpu_sum = 0.0;
        gpu_frames = 0;
        frames = 0;
        late = 0;
    }

    /// Intervals longer than this are loads.
    static constexpr double Stall = 0.25;

    const Mode mode;
    Plan plan;
    bool measured{};
    bool started{};
    bool at_fallback{};
    double window_start{};
    double gpu_sum{};
    int gpu_frames{};
    double parts_gpu_sum{}; // The figures of Gpu(..., parts), for the logs only.
    double parts_cp_sum{};
    int parts_frames{};
    int parts_cp_frames{};
    int frames{};
    int late{};
    int over{};       // Seconds in a row at the base with the GPU over 95%.
    double good{};    // Seconds in a row at the fallback good enough to go back.
    double need{10.0};
    double base_since{-1.0}; // When the base came back, -1 while it did not (or is not on).
    Switch last;
    Seen seen;
};

} // namespace Core::KnownTitle::Pacing
