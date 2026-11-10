// Checks the shader test of the GPU bench (video_core/renderer_vulkan/gpu_bench.h, compiled here
// alone with a made-up clock and logging): the diagnostics gate, the count of the scene's pixel
// shaders, the schedule of what is left out (with the steps "without its pixels" and without them,
// as on a renderer that cannot make them), the cost worked out from the frames' GPU times, and
// the lines at the start and at the end on another renderer.
//
//   g++ -std=c++20 -Wall -Wextra -I tools/tests/gpu_bench_stubs -I shadps4-arm64-main/src
//       tools/tests/gpu_bench_test.cpp shadps4-arm64-main/src/video_core/renderer_vulkan/gpu_bench.cpp
//       -o build/tests/gpu_bench_test
//   build/tests/gpu_bench_test        (the test mode)
//   build/tests/gpu_bench_test off    (diagnostics mode off: nothing starts)
#include <cstdio>
#include <cstdlib>
#include <string>
#include <string_view>

#include "common/logging/log.h"
#include "video_core/renderer_vulkan/gpu_bench.h"

namespace GB = Vulkan::GpuBench;

static int failures = 0;

static void Check(bool ok, const std::string& what) {
    std::printf("%s  %s\n", ok ? "ok  " : "FAIL", what.c_str());
    failures += ok ? 0 : 1;
}

static s64 g_now = 0;
static s64 Now() {
    return g_now;
}

static bool Logged(std::string_view part) {
    for (const std::string& line : GpuBenchTestLog::Lines()) {
        if (line.find(part) != std::string::npos) {
            return true;
        }
    }
    return false;
}

static size_t Position(std::string_view part) {
    size_t i = 0;
    for (const std::string& line : GpuBenchTestLog::Lines()) {
        if (line.find(part) != std::string::npos) {
            return i;
        }
        ++i;
    }
    return size_t(-1);
}

// The scene of the test: pixel shaders A (10 draws a frame), B (3), C (1) in scene passes, D in one
// that is not (a draw in a small pass). What a frame costs the GPU: 2 ms of the rest, and A 6 ms,
// B 1.5 ms, C 0.5 ms for as long as their draws are made; a quarter of that with their vertices
// only. So the frame is 10 ms.
struct Shader {
    u64 fs;
    u64 vs;
    int draws;
    double ms;
};
constexpr Shader Scene[] = {{0xA, 0xA1, 10, 6.0}, {0xB, 0xB1, 3, 1.5}, {0xC, 0xC1, 1, 0.5}};
constexpr u64 OtherFs = 0xD;

struct Run {
    bool saw_no_pixels = false;
    bool other_touched = false;
};

/// Makes frames of 10 ms until the test is over; `buffers` command buffers make each frame's time.
static Run Frames(u64 buffers) {
    Run run;
    for (int frame = 0; GB::ShaderTestRunning() && frame < 20000; ++frame) {
        g_now += 10'000'000;
        GB::Current();
        double gpu = 2.0;
        for (const Shader& s : Scene) {
            for (int d = 0; d < s.draws; ++d) {
                const auto action = GB::ShaderDraw(true, s.fs, s.vs, false, 1000);
                run.saw_no_pixels = run.saw_no_pixels || action == GB::DrawAction::NoPixels;
                gpu += action == GB::DrawAction::Draw        ? s.ms / s.draws
                       : action == GB::DrawAction::NoPixels ? s.ms / s.draws / 4
                                                            : 0.0;
            }
        }
        const auto other = GB::ShaderDraw(false, OtherFs, 1, false, 1000);
        run.other_touched = run.other_touched || other != GB::DrawAction::Draw;
        GB::NoteFrame();
        GB::NoteGpuTime(0, GB::TimingTag(), gpu, 0.0, buffers);
    }
    return run;
}

static void Off() {
    GB::SetClockForTest(Now);
    g_now = 1'000'000'000'000;
    GB::Start();
    GB::StartOn("Other", false);
    Check(!GB::ShaderTestRunning(), "diagnostics mode off: neither start does anything");
    Check(GpuBenchTestLog::Lines().empty(), "diagnostics mode off: nothing logged");
}

static void Test() {
    GB::SetClockForTest(Now);
    g_now = 1'000'000'000'000;
    Check(!GB::ShaderTestRunning(), "not running before the start");
    Check(GB::TimingTag() == -1, "no step before the start");
    Check(GB::ShaderDraw(true, 0xA, 1, false, 1) == GB::DrawAction::Draw, "a draw is made before the start");

    // --- Vulkan's way: Start(), the steps with and without the pixels ---
    GpuBenchTestLog::Lines().clear();
    GB::Start();
    Check(GB::ShaderTestRunning(), "Start() starts the shader test");
    Check(Logged("GPU_SHADER_BENCH: started: 4 s counting"), "Start() logs the start");
    Check(!Logged("started on"), "Start() has no renderer line");
    g_now += 2'000'000'000;
    Check(GB::TimingTag() == -1, "the count has no step");
    Check(GB::ShaderDraw(true, 0xA, 1, false, 1) == GB::DrawAction::Draw, "the count leaves every draw be");
    GB::Start();  // again: the count of the first try is gone
    Run run = Frames(1);
    Check(!GB::ShaderTestRunning(), "the test is over after its result");
    Check(run.saw_no_pixels, "a draw was told to run its vertices only");
    Check(!run.other_touched, "a draw outside the scene passes is never touched");
    Check(Logged("counted 3 pixel shaders in the scene passes"), "three shaders counted (D is not in a scene pass)");
    Check(Logged("step 1 of 12: as they are") && Logged("step 12 of 12: as they are"), "12 steps: 3 x (as they are, pixels, out) + 3");
    Check(Logged("step 2 of 12: fs 0xa without its pixels (vertices only)"), "step 2 is shader A without its pixels");
    Check(Logged("step 3 of 12: without fs 0xa") && Logged("step 11 of 12: without all 3"), "steps without A and without all");
    Check(Logged("done; you can move"), "the end of the steps is logged");
    Check(Logged("fs 0xa (vs 0xa1; 99"), "the census says what A is made of (about 1000 draws/s)");
    Check(Logged("without it GPU 4.00 against 10.00 = -6.00 ms"), "A out: 4.00 ms against 10.00");
    Check(Logged("without its pixels GPU 5.50 against 10.00 = -4.50 ms"), "A without its pixels: 5.50 ms against 10.00");
    Check(Logged("without it GPU 8.50 against 10.00 = -1.50 ms"), "B out: 8.50 ms against 10.00");
    Check(Logged("without it GPU 9.50 against 10.00 = -0.50 ms"), "C out: 9.50 ms against 10.00");
    Check(Logged("all 3 at once: GPU 2.00 against 10.00 = -8.00 ms"), "all out: 2.00 ms against 10.00");
    Check(Logged("steps as they are from 10.00 to 10.00"), "the steps as they are agree");
    Check(Logged("100.0 fps, GPU 10.00 ms a frame"), "100 frames a second in the timed part of a step");
    Check(!Logged("ended on"), "Start() logs no end line");

    // --- another renderer's way: StartOn(), no step for the pixels ---
    GpuBenchTestLog::Lines().clear();
    g_now += 5'000'000'000;
    GB::StartOn("Other", false);
    Check(GB::ShaderTestRunning(), "StartOn() starts the shader test");
    Check(Logged("started on Other; no steps without a draw's pixels"), "StartOn() logs the start on the renderer");
    Check(Logged("then up to 19 steps"), "up to 8 x 2 + 3 steps");
    run = Frames(3);
    Check(!GB::ShaderTestRunning(), "the test is over after its result");
    Check(!run.saw_no_pixels, "no draw was told to run its vertices only");
    Check(!run.other_touched, "a draw outside the scene passes is never touched");
    Check(Logged("step 9 of 9: as they are") && !Logged("step 10 of"), "9 steps: 3 x (as they are, out) + 3");
    Check(!Logged("without its pixels (vertices only)"), "no step names the pixels");
    Check(Logged("without it GPU 4.00 against 10.00 = -6.00 ms"), "A out: 4.00 ms against 10.00");
    Check(Logged("without its pixels not made on this renderer"), "the pixels are said not to be made");
    Check(Logged("without it GPU 9.50 against 10.00 = -0.50 ms"), "C out: 9.50 ms against 10.00");
    Check(Logged("all 3 at once: GPU 2.00 against 10.00 = -8.00 ms"), "all out: 2.00 ms against 10.00");
    Check(Logged("(750 command buffers, 0 without a usable whole time)"), "3 buffers a frame, 250 timed frames");
    Check(Logged("ended on Other: 3 pixel shaders counted, 3 of them left out in turn, 32 s"), "the end line: counted, left out, seconds");
    Check(Position("ended on") > Position("all 3 at once"), "the end line comes after the result");

    // --- StartOn() with env_ab: no step changes the environment; the log lists the switches ---
    GpuBenchTestLog::Lines().clear();
    g_now += 5'000'000'000;
    unsetenv("VPKENGINE_MAX_ANISO");
    setenv("VPGCN_FETCH_GUARDS", "1", 1);
    GB::StartOn("Other", false, true);
    Check(Logged("then up to 19 steps"), "env_ab adds no steps: still up to 8 x 2 + 3");
    run = Frames(1);
    bool env_untouched = std::getenv("VPKENGINE_MAX_ANISO") == nullptr && std::getenv("VPGCN_FETCH_GUARDS") != nullptr &&
                         std::string_view{std::getenv("VPGCN_FETCH_GUARDS")} == "1";
    Check(!GB::ShaderTestRunning(), "the env_ab test is over after its result");
    Check(Logged("step 9 of 9: as they are") && !Logged("step 10 of"), "9 steps, none for a switch");
    Check(!Logged("A/B all together") && !Logged("step 1 of 9: A/B"), "no A/B step in the steps");
    Check(Logged("A/B anisotropy 1 (VPKENGINE_MAX_ANISO=1): no step in the middle of a session") &&
              Logged("start the session with the variable set (not set now)"),
          "anisotropy: no step, said so, not set");
    Check(Logged("A/B vertex shaders in fast math (VPKENGINE_VS_FASTMATH=1): no step"), "fast math: no step, said so");
    Check(Logged("A/B A3 off (fetch guards) (VPGCN_FETCH_GUARDS=1): no step") && Logged("(set to '1' now)"),
          "fetch guards: no step, and set now");
    Check(Logged("A/B A2 off (depth-only split) (VPKENGINE_DEPTH_ONLY_SPLIT=1): no step"), "A2 off: no step, said so");
    Check(Logged("A/B keepSamples off (VPKENGINE_MSAA_CUT_SAMPLES_OFF=1): no step"), "keepSamples off: no step, said so");
    Check(env_untouched, "the test never changes the environment");
    unsetenv("VPGCN_FETCH_GUARDS");
    GpuBenchTestLog::Lines().clear();
    GB::StartOn("Other", false);
    Frames(1);
    Check(!Logged("A/B "), "without env_ab nothing about the switches is logged");

    // --- no GPU times at all ---
    GpuBenchTestLog::Lines().clear();
    GB::StartOn("Other", false);
    for (int frame = 0; GB::ShaderTestRunning() && frame < 20000; ++frame) {
        g_now += 10'000'000;
        GB::Current();
        for (const Shader& s : Scene) {
            GB::ShaderDraw(true, s.fs, s.vs, false, 1000);
        }
        GB::NoteFrame();
    }
    Check(Logged("result: no GPU times"), "without GPU times the result says so");
    Check(Logged("ended on Other"), "and the test still ends");

    // --- nothing in the scene ---
    GpuBenchTestLog::Lines().clear();
    GB::StartOn("Other", false);
    for (int frame = 0; GB::ShaderTestRunning() && frame < 20000; ++frame) {
        g_now += 10'000'000;
        GB::Current();
        GB::NoteFrame();
    }
    Check(Logged("counted 0 pixel shaders") && Logged("nothing (no scene draws seen)"), "no scene draws: nothing to leave out");
    Check(Logged("ended on Other: 0 pixel shaders counted, 0 of them left out in turn"), "and it ends");
}

int main(int argc, char** argv) {
    if (argc > 1 && std::string_view{argv[1]} == "off") {
        Off();
    } else {
        setenv("SHADPS4_DIAGNOSTICS", "1", 1);
        Test();
    }
    std::printf(failures == 0 ? "all ok\n" : "%d FAILED\n", failures);
    return failures == 0 ? 0 : 1;
}
