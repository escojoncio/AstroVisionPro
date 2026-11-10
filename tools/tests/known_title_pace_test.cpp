// Checks how many refreshes of the headset a frame of the title is given: the plan made from the
// panel's rate (a base pace and a fallback one) and the regulator that chooses between the two
// from the frames' intervals and the GPU time (known_title_pace.h, which holds nothing of the
// emulator and is compiled here alone).
//
//   g++ -std=c++20 -Wall -Wextra -I shadps4-arm64-main/src tools/tests/known_title_pace_test.cpp
//       -o build/tests/known_title_pace_test
//   build/tests/known_title_pace_test
//
// Frames are made up here at intervals that are exact in binary (1/64 s, 1/32 s), so that a
// window comes to exactly one second.
#include <cmath>
#include <cstdio>
#include <optional>
#include <string>

#include "core/known_title_pace.h"

using namespace Core::KnownTitle::Pacing;

static int failures = 0;

static void Check(bool ok, const std::string& what) {
    std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what.c_str());
    failures += ok ? 0 : 1;
}

static bool Near(double a, double b, double within = 0.01) {
    return std::fabs(a - b) <= within;
}

// At 100 Hz the base pace is 2 refreshes (20 ms), the fallback 3 (30 ms).
constexpr double BaseFrame = 1.0 / 64;      // on time at the base (and at the fallback)
constexpr double FallbackFrame = 1.0 / 32;  // on time at the fallback, a missed refresh at the base
constexpr double LateFallback = 3.0 / 64;   // a missed refresh at the fallback (over 37.5 ms)
constexpr double GpuLight = 0.010;          // under 92% of the base frame (18.4 ms)
constexpr double GpuGood = 0.015;
constexpr double GpuHeavy = 0.0195;         // over 95% of the base frame (19 ms)

/// A regulator fed made-up frames.
struct Rig {
    Regulator reg;
    double t = 1000.0;
    int switches = 0;
    std::optional<Figures> parts; ///< Told with each frame's GPU time when set.

    explicit Rig(Mode mode, double panel = 100.0) : reg{mode} {
        reg.SetPlan(MakePlan(panel));
    }

    /// One frame, `gpu` seconds of GPU work on it (no figure when below 0).
    bool Frame(double interval, double gpu) {
        t += interval;
        if (gpu >= 0.0) {
            if (parts) {
                reg.Gpu(gpu, 1, *parts);
            } else {
                reg.Gpu(gpu, 1);
            }
        }
        const bool changed = reg.Frame(t, interval);
        switches += changed ? 1 : 0;
        return changed;
    }

    /// Frames for `seconds`; every `every`th one takes `odd` seconds instead (0 for none).
    /// True when the pace changed meanwhile.
    bool Run(double seconds, double interval, double gpu, int every = 0, double odd = 0.0) {
        const double end = t + seconds;
        bool changed = false;
        for (int k = 1; t < end; ++k) {
            changed |= Frame(every != 0 && k % every == 0 ? odd : interval, gpu);
        }
        return changed;
    }

    /// Frames until the pace is `pace`: the seconds that took, -1 if `limit` passed first.
    double Until(int pace, double limit, double interval, double gpu, int every = 0,
                 double odd = 0.0) {
        const double start = t;
        for (int k = 1; t - start < limit; ++k) {
            Frame(every != 0 && k % every == 0 ? odd : interval, gpu);
            if (reg.Pace() == pace) {
                return t - start;
            }
        }
        return -1.0;
    }

    /// Takes the first step, to the fallback, once the GPU time is known.
    void Start() {
        Frame(FallbackFrame, GpuGood);
    }
};

static void CheckPlan(double panel, int base, int fallback, double base_fps, double fallback_fps) {
    const Plan plan = MakePlan(panel);
    Check(plan.base == base && plan.fallback == fallback &&
              Near(plan.BaseFps(), base_fps) && Near(plan.FallbackFps(), fallback_fps),
          "plan at " + std::to_string(static_cast<int>(panel)) + " Hz: base " +
              std::to_string(plan.base) + ", fallback " + std::to_string(plan.fallback));
}

static void PlanFromPanel() {
    CheckPlan(100, 2, 3, 50.0, 33.33);
    CheckPlan(90, 2, 3, 45.0, 30.0);
    CheckPlan(120, 2, 3, 60.0, 40.0);
    CheckPlan(72, 2, 0, 36.0, 0.0);  // 24 fps would be the fallback: none
    CheckPlan(60, 1, 2, 60.0, 30.0);
    CheckPlan(144, 3, 4, 48.0, 36.0);
    CheckPlan(0, 2, 3, 60.0, 40.0);  // a rate that cannot be one is taken for 120
}

static void StartsAtTheFallback() {
    Rig rig{Mode::Auto};
    Check(rig.reg.Pace() == 2, "the base before the GPU time is known");
    rig.Run(5.0, FallbackFrame, -1.0);
    Check(rig.reg.Pace() == 2 && rig.switches == 0, "... and for as long as it is not");
    Check(rig.Frame(FallbackFrame, GpuGood), "the first GPU time is a step");
    Check(rig.reg.Pace() == 3 && rig.reg.AtFallback() && rig.reg.Last().why == Regulator::Why::Start,
          "... to the fallback");
    Rig none{Mode::Auto, 72.0};
    none.Run(5.0, FallbackFrame, GpuGood);
    Check(none.reg.Pace() == 2 && none.switches == 0, "no fallback at 72 Hz: stays at the base");
}

static void PromotionAfterTenGoodSeconds() {
    Rig rig{Mode::Auto};
    rig.Start();
    const double took = rig.Until(2, 60.0, FallbackFrame, GpuGood);
    Check(Near(took, 10.0, 0.05), "back to the base after 10 s of good seconds (" +
                                      std::to_string(took) + ")");
    Check(rig.reg.Last().why == Regulator::Why::Good && !rig.reg.Last().to_fallback,
          "... decided as a good run");

    Rig dear{Mode::Auto};
    dear.Start();
    Check(!dear.Run(40.0, FallbackFrame, 0.019), "a GPU over 92% of the base frame never goes back");
    Check(dear.reg.Pace() == 3, "... it stays at the fallback");

    Rig some{Mode::Auto};
    some.Start();
    Check(some.Until(2, 30.0, FallbackFrame, GpuGood, 32, LateFallback) > 0.0,
          "one late frame a second is allowed (5%, at least one)");
    Rig many{Mode::Auto};
    many.Start();
    many.Run(30.0, FallbackFrame, GpuGood, 16, LateFallback);
    Check(many.reg.Pace() == 3, "two or more late frames a second are too many");

    Rig blind{Mode::Auto};
    blind.Start();
    blind.Run(30.0, FallbackFrame, -1.0);
    Check(blind.reg.Pace() == 3, "seconds without a GPU time do not count as good");

    Rig streak{Mode::Auto};
    streak.Start();
    streak.Run(9.0, FallbackFrame, GpuGood);
    streak.Run(1.0, FallbackFrame, 0.019);
    streak.Run(9.0, FallbackFrame, GpuGood);
    Check(streak.reg.Pace() == 3, "a heavy second in the middle starts the count again");
}

static void FastDemotionOnMissedRefreshes() {
    Rig rig{Mode::Auto};
    rig.Start();
    rig.Until(2, 60.0, FallbackFrame, GpuGood);
    rig.Run(2.0, BaseFrame, GpuLight);
    Check(rig.reg.Pace() == 2 && rig.switches == 2, "frames on time at the base stay there");
    const double took = rig.Until(3, 5.0, FallbackFrame, GpuLight);
    Check(Near(took, 10 * FallbackFrame, 0.001) && rig.reg.Last().why == Regulator::Why::Burst,
          "ten frames in 0.3 s that all missed their refresh leave the base at once (" +
              std::to_string(took) + " s)");
    Check(rig.reg.Last().frames >= 10 && rig.reg.Last().late == rig.reg.Last().frames,
          "... with the figures that decided it");

    Rig a_tenth{Mode::Auto};
    a_tenth.Start();
    a_tenth.Until(2, 60.0, FallbackFrame, GpuLight);
    a_tenth.Run(10.0, BaseFrame, GpuLight, 10, FallbackFrame);
    Check(a_tenth.reg.Pace() == 2, "a tenth of the frames late stays at the base");

    Rig a_fifth{Mode::Auto};
    a_fifth.Start();
    a_fifth.Until(2, 60.0, FallbackFrame, GpuLight);
    const double slow = a_fifth.Until(3, 5.0, BaseFrame, GpuLight, 5, FallbackFrame);
    Check(slow > 0.9 && slow < 1.2 && a_fifth.reg.Last().why == Regulator::Why::Missed,
          "a fifth late goes after a second (" + std::to_string(slow) + " s)");
}

static void DemotionAfterTwoHeavyWindows() {
    Rig rig{Mode::Auto};
    rig.Start();
    rig.Until(2, 60.0, FallbackFrame, GpuLight);
    const double took = rig.Until(3, 10.0, BaseFrame, GpuHeavy);
    Check(Near(took, 2.0, 0.05) && rig.reg.Last().why == Regulator::Why::Heavy,
          "two seconds of GPU over 95% of the base frame go to the fallback (" +
              std::to_string(took) + " s)");
    Check(Near(rig.reg.Last().gpu, GpuHeavy, 1e-9), "... with the GPU time that decided it");

    Rig apart{Mode::Auto};
    apart.Start();
    apart.Until(2, 60.0, FallbackFrame, GpuLight);
    apart.Run(1.0, BaseFrame, GpuHeavy);
    apart.Run(1.0, BaseFrame, GpuLight);
    apart.Run(1.0, BaseFrame, GpuHeavy);
    apart.Run(1.0, BaseFrame, GpuLight);
    Check(apart.reg.Pace() == 2, "heavy seconds that are not in a row stay at the base");

    Rig close{Mode::Auto};
    close.Start();
    close.Until(2, 60.0, FallbackFrame, GpuLight);
    close.Run(20.0, BaseFrame, 0.0185);
    Check(close.reg.Pace() == 2, "a GPU between 92% and 95% holds the base");
}

static void BackOffDoublesAndResets() {
    Rig rig{Mode::Auto};
    rig.Start();
    Check(Near(rig.reg.Need(), 10.0), "the way back asks for 10 s at first");
    const double expected[] = {20.0, 40.0, 80.0, 120.0, 120.0};
    double need = 10.0;
    bool all = true;
    for (const double next : expected) {
        const double back = rig.Until(2, 400.0, FallbackFrame, GpuLight);
        all = all && Near(back, need, 0.05);
        rig.Until(3, 10.0, BaseFrame, GpuHeavy);  // fails 2 s after it came back
        all = all && Near(rig.reg.Need(), next);
        need = next;
    }
    Check(all, "a base that fails soon after it came back doubles the wait: 20, 40, 80, 120, 120");

    const double back = rig.Until(2, 400.0, FallbackFrame, GpuLight);
    Check(Near(back, 120.0, 0.05), "... and the wait is kept");
    rig.Run(61.0, BaseFrame, GpuLight);
    Check(rig.reg.Pace() == 2 && Near(rig.reg.Need(), 10.0), "a base that holds 60 s resets it to 10");
    rig.Until(3, 10.0, BaseFrame, GpuHeavy);
    Check(Near(rig.reg.Need(), 10.0), "... and failing then does not double it");

    rig.Until(2, 100.0, FallbackFrame, GpuLight);
    rig.Run(30.0, BaseFrame, GpuLight);
    rig.Until(3, 10.0, BaseFrame, GpuHeavy);
    Check(Near(rig.reg.Need(), 10.0), "a base that fails after 30 s leaves the wait as it was");
    rig.Until(2, 100.0, FallbackFrame, GpuLight);
    rig.Until(3, 10.0, BaseFrame, GpuHeavy);
    Check(Near(rig.reg.Need(), 20.0), "... and one that fails within 20 s doubles it");
}

static void FixedModesNeverSwitch() {
    Rig steady{Mode::Steady};
    Check(steady.reg.Pace() == 3, "steady is the fallback");
    steady.Run(30.0, BaseFrame, GpuLight);
    steady.Run(30.0, FallbackFrame, GpuHeavy, 3, LateFallback);
    Check(steady.reg.Pace() == 3 && steady.switches == 0, "... whatever frames do");

    Rig base{Mode::Base};
    Check(base.reg.Pace() == 2, "base is the base");
    base.Run(30.0, FallbackFrame, GpuHeavy);
    base.Run(30.0, BaseFrame, GpuLight);
    Check(base.reg.Pace() == 2 && base.switches == 0, "... whatever frames do");

    Rig no_fallback{Mode::Steady, 72.0};
    Check(no_fallback.reg.Pace() == 2, "steady where there is no fallback is the base");
}

static void HitchesAndLoadsAreIgnored() {
    Rig rig{Mode::Auto};
    rig.Start();
    rig.Until(2, 60.0, FallbackFrame, GpuLight);
    rig.Run(10.0, BaseFrame, GpuLight, 8, 0.125);  // streaming: over 3 periods
    Check(rig.reg.Pace() == 2 && rig.reg.Window().late == 0, "intervals past 3 periods do not count");
    rig.Run(10.0, BaseFrame, GpuLight, 20, 0.5);  // a load: over 250 ms
    Check(rig.reg.Pace() == 2 && rig.reg.Window().late == 0, "intervals past 250 ms do not count");

    Rig at_fallback{Mode::Auto};
    at_fallback.Start();
    Check(at_fallback.Until(2, 40.0, FallbackFrame, GpuLight, 10, 0.5) > 0.0,
          "a load does not break the run of good seconds either");
}

static void GpuTimeIsTheGpusOwnWhereKnown() {
    // Frames in flight 95% of the time (each waits behind the one before) while the GPU's
    // command buffers run 15 ms of every 31.25 ms frame: a GPU with room for the base.
    const double in_flight = 0.95 * FallbackFrame;
    const double own = GpuFrameTime(32 * GpuGood, 1.0, FallbackFrame, in_flight);
    Check(Near(own, GpuGood, 1e-9), "the GPU's own time is what a frame is said to take (" +
                                        std::to_string(own * 1e3) + " ms)");
    Rig rig{Mode::Auto};
    rig.Start();
    const double took = rig.Until(2, 60.0, FallbackFrame, own);
    Check(Near(took, 10.0, 0.05),
          "... and goes back to the base after 10 s whatever is in flight (" +
              std::to_string(took) + ")");
    Check(Near(GpuFrameTime(2.0, 1.0, FallbackFrame, in_flight), FallbackFrame, 1e-9),
          "a GPU that never rests worked the whole frame");

    const double guess = GpuFrameTime(-1.0, 1.0, FallbackFrame, in_flight);
    Rig blind{Mode::Auto};
    blind.Start();
    Check(Near(guess, in_flight, 1e-9) && !blind.Run(40.0, FallbackFrame, guess),
          "without the GPU's own time the frames in flight decide, as before");
}

static void ASlowCommandThreadKeepsTheFallback() {
    // The GPU works 17 ms a frame (room for the base, 18.4) and the thread that makes the frames
    // 28 ms: a frame every 31.25 ms is all it can do, the base would fail at once.
    constexpr double Gpu = 0.017;
    const double busy = FrameWorkTime(Gpu, 32 * 0.028, 1.0, FallbackFrame);
    Check(Near(busy, 0.028, 1e-9), "a frame takes what its slowest part takes (" +
                                       std::to_string(busy * 1e3) + " ms)");
    Rig slow{Mode::Auto};
    slow.Start();
    slow.Run(600.0, FallbackFrame, busy);
    Check(slow.reg.Pace() == 3 && slow.switches == 1,
          "a command thread that takes 28 ms a frame never tries the base (" +
              std::to_string(slow.switches - 1) + " changes)");

    // 17 ms on both: the base, and it holds.
    Rig fits{Mode::Auto};
    fits.Start();
    const double took =
        fits.Until(2, 60.0, FallbackFrame, FrameWorkTime(Gpu, 32 * 0.017, 1.0, FallbackFrame));
    fits.Run(580.0, BaseFrame, FrameWorkTime(Gpu, 64 * 0.017, 1.0, BaseFrame));
    Check(Near(took, 10.0, 0.05) && fits.reg.Pace() == 2 && fits.switches == 2,
          "17 ms on the GPU and on the command thread goes to the base and stays");
    Check(Near(FrameWorkTime(Gpu, -1.0, 1.0, FallbackFrame), Gpu, 1e-12),
          "where the thread's time is not told the GPU's decides alone");
}

static void PlanChangesWithThePanel() {
    Rig rig{Mode::Auto};
    rig.Start();
    Check(rig.reg.Pace() == 3, "100 Hz: at the fallback");
    rig.reg.SetPlan(MakePlan(72.0));
    Check(rig.reg.Pace() == 2 && !rig.reg.AtFallback(), "a panel that leaves no fallback: the base");
    rig.reg.SetPlan(MakePlan(120.0));
    rig.Frame(FallbackFrame, GpuGood);
    Check(rig.reg.Pace() == 3, "... and at the fallback again when there is one");
}

static void LogsSayWhichFigureDecided() {
    // CpFrameTime is the share FrameWorkTime takes the more of.
    constexpr double Gpus[] = {0.005, 0.017, 0.028};
    constexpr double Cps[] = {-1.0, 0.0, 32 * 0.010, 32 * 0.028, 100.0};
    bool same = true;
    for (const double gpu : Gpus) {
        for (const double cp : Cps) {
            same = same && FrameWorkTime(gpu, cp, 1.0, FallbackFrame) ==
                               std::max(gpu, CpFrameTime(cp, 1.0, FallbackFrame));
        }
    }
    Check(same && CpFrameTime(-1.0, 1.0, FallbackFrame) < 0.0 && CpFrameTime(1.0, 0.0, FallbackFrame) < 0.0,
          "CpFrameTime: what FrameWorkTime takes the more of, below zero where not told");

    // The command thread is the more: it decided, and both figures are in the window.
    constexpr double Thread = 0.028;
    Rig by_thread{Mode::Auto};
    by_thread.Start();
    by_thread.parts = Figures{.gpu = GpuGood, .cp = Thread};
    by_thread.Run(1.0, FallbackFrame, Thread);
    const Regulator::Seen& seen = by_thread.reg.Window();
    Check(seen.figures.by_cp && Near(seen.figures.gpu, GpuGood, 1e-9) && Near(seen.figures.cp, Thread, 1e-9) &&
              Near(seen.gpu, Thread, 1e-9),
          "the command thread's 28 ms is the figure the window went by");
    Check(std::string{DecidedBy(seen.figures)} == "command thread" &&
              FiguresText(seen.figures) == "GPU 15.0 ms, command thread 28.0 ms",
          "... and the text says so, with both: " + FiguresText(seen.figures));

    // The GPU is the more.
    Rig by_gpu{Mode::Auto};
    by_gpu.Start();
    by_gpu.parts = Figures{.gpu = 0.022, .cp = 0.018};
    by_gpu.Run(1.0, FallbackFrame, 0.022);
    Check(!by_gpu.reg.Window().figures.by_cp && std::string{DecidedBy(by_gpu.reg.Window().figures)} == "GPU" &&
              FiguresText(by_gpu.reg.Window().figures) == "GPU 22.0 ms, command thread 18.0 ms",
          "the GPU's 22 ms against the thread's 18 decides, and the text says so");

    // The renderer does not tell the thread's time.
    Rig untold{Mode::Auto};
    untold.Start();
    untold.parts = Figures{.gpu = GpuGood};
    untold.Run(1.0, FallbackFrame, GpuGood);
    Check(!untold.reg.Window().figures.by_cp && untold.reg.Window().figures.cp < 0.0 &&
              FiguresText(untold.reg.Window().figures) == "GPU 15.0 ms, command thread not told",
          "no thread time told: the GPU decides alone, and the text says that");

    // Mixed window: the thread is the more on 33 frames of 64, but the GPU's mean is the greater.
    Rig mixed{Mode::Auto};
    mixed.Start();
    for (int k = 0; k < 64; ++k) {
        const bool thread = k < 33;
        mixed.parts = thread ? Figures{.gpu = 0.015, .cp = 0.020} : Figures{.gpu = 0.040, .cp = 0.005};
        mixed.Frame(BaseFrame, mixed.parts->gpu);
    }
    const Figures& blend = mixed.reg.Window().figures;
    Check(mixed.reg.Window().frames == 64 && !blend.by_cp && Near(blend.gpu, 0.0271, 1e-4) &&
              Near(blend.cp, 0.0127, 1e-4),
          "the mean decides, not the count of frames: " + FiguresText(blend) + " by " + DecidedBy(blend));

    // A switch carries the figures of the window that made it (the way back to the base).
    Rig back{Mode::Auto};
    back.Start();
    back.parts = Figures{.gpu = GpuGood, .cp = 0.012};
    const double took = back.Until(2, 60.0, FallbackFrame, GpuGood);
    const Regulator::Switch& made = back.reg.Last();
    Check(took > 0.0 && made.why == Regulator::Why::Good && !made.figures.by_cp &&
              Near(made.figures.gpu, GpuGood, 1e-9) && Near(made.figures.cp, 0.012, 1e-9),
          "the switch back to the base carries both figures");

    // The figures change nothing of the rule: the same frames, told with and without them, make the same changes.
    Rig plain{Mode::Auto}, told{Mode::Auto};
    plain.Start();
    told.Start();
    told.parts = Figures{.gpu = GpuGood, .cp = 0.012};
    bool alike = true;
    for (int k = 0; k < 64 * 40; ++k) {
        const bool heavy = k > 64 * 20 && k < 64 * 26;
        const double gpu = heavy ? GpuHeavy : GpuGood;
        const double interval = plain.reg.Pace() == 2 ? BaseFrame : FallbackFrame;
        plain.Frame(interval, gpu);
        told.Frame(interval, gpu);
        alike = alike && plain.reg.Pace() == told.reg.Pace() && plain.switches == told.switches;
    }
    Check(alike && plain.switches > 1, "told with the figures or not, the pace is the same (" +
                                           std::to_string(plain.switches) + " changes)");
}

int main() {
    PlanFromPanel();
    StartsAtTheFallback();
    PromotionAfterTenGoodSeconds();
    FastDemotionOnMissedRefreshes();
    DemotionAfterTwoHeavyWindows();
    BackOffDoublesAndResets();
    FixedModesNeverSwitch();
    HitchesAndLoadsAreIgnored();
    PlanChangesWithThePanel();
    GpuTimeIsTheGpusOwnWhereKnown();
    ASlowCommandThreadKeepsTheFallback();
    LogsSayWhichFigureDecided();
    std::printf("%s\n", failures == 0 ? "all ok" : "FAILED");
    return failures == 0 ? 0 : 1;
}
