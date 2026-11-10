// SPDX-FileCopyrightText: Copyright 2024-2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

// The GPU tests of gpu_bench.h. Nothing here touches Vulkan: the renderers feed it (the draws of
// the Vulkan rasterizer, vk_rasterizer.cpp; the adapter's, platform/visionos/vpkengine_renderer.mm)
// and read from it what to do with a draw.

#include "video_core/renderer_vulkan/gpu_bench.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iterator>
#include <mutex>
#include <ranges>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include <fmt/format.h>
#include "common/diagnostics.h"
#include "common/logging/log.h"

namespace Vulkan {

namespace GpuBench {

namespace {
constexpr Mode Steps[] = {Mode::Normal,          Mode::NoFragments,     Mode::NoGeometry,
                          Mode::NoDepthOnlyPasses, Mode::NoGeometryShaders, Mode::Normal,
                          Mode::NoFragments,     Mode::NoGeometry,      Mode::NoDepthOnlyPasses,
                          Mode::NoGeometryShaders, Mode::Normal};
constexpr auto StepLength = std::chrono::seconds(10);
std::atomic<s64> g_started{0};
std::atomic<int> g_step{-1};

const char* Name(Mode mode) {
    switch (mode) {
    case Mode::Normal:
        return "as they are";
    case Mode::NoFragments:
        return "without pixels (vertices only)";
    case Mode::NoGeometry:
        return "three vertices a draw (next to no geometry)";
    case Mode::NoDepthOnlyPasses:
        return "without depth-only passes (shadows, depth prepass)";
    case Mode::NoGeometryShaders:
        return "without geometry shader draws";
    }
    return "?";
}
} // namespace

// --- the shader test (gpu_bench.h) ---

namespace {

constexpr s64 CensusNs = 4'000'000'000;
constexpr s64 ShaderStepNs = 3'000'000'000;
// A step's first half second goes untimed: the frames the GPU was still on are the last step's.
constexpr s64 SettleNs = 500'000'000;
constexpr size_t MaxCandidates = 8;
// After the last step, the GPU's times for it come in a few frames late.
constexpr s64 ReportDelayNs = 1'000'000'000;

struct ShaderCount {
    u64 draws{};
    u64 vertices{};
    u64 vs_hash{};
    bool has_gs{};
};
/// What a step measures.
struct Step {
    enum Kind { Base, NoPixels, Out, All } kind{Base};
    int candidate{-1};
};
struct StepTime {
    double ms{};       // the timer's command buffers with a usable time
    double scene_ms{}; // the scene passes in them (ShaderDraw's kind)
    u64 buffers{};
    u64 unusable{}; // command buffers without a usable whole time (their passes still count)
};

struct ShaderTest {
    std::mutex mutex;
    std::atomic<s64> started{0};
    std::atomic<int> logged_step{-2};
    std::atomic<int> num_steps{-1}; // steps.size() once chosen
    bool counted{};                 // the candidates are chosen
    bool reported{};
    std::unordered_map<u64, ShaderCount> census;
    std::vector<std::pair<u64, ShaderCount>> candidates;
    std::vector<Step> steps;
    // What the step now on does to the draws of the pixel shader `hash` (a hash may be 0).
    std::atomic<u64> hash{0};
    std::atomic<int> action{int(DrawAction::Draw)};
    std::atomic<bool> all_out{false};
    std::unordered_map<u32, std::vector<StepTime>> times; // by timer
    std::vector<u64> frames;                               // presented in each step's timed part
    std::unordered_map<u64, std::string> states;           // a draw's state, by pixel shader
    // StartOn: the renderer it runs on (null: Vulkan's), and whether it can leave a draw's pixels
    // out on their own (without it there are no steps for that).
    const char* renderer{};
    bool pixels_out{true};
};
ShaderTest g_shaders;

/// SPIR-V of every shader compiled, by key hash (NoteSpirv), up to a limit.
struct SpirvStore {
    std::mutex mutex;
    std::unordered_map<u64, std::vector<u32>> by_hash;
    size_t bytes{};
};
SpirvStore g_spirv;
constexpr size_t MaxSpirvBytes = 24ull << 20;

std::string Base64(std::span<const u32> words) {
    static constexpr char Table[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const auto* bytes = reinterpret_cast<const u8*>(words.data());
    const size_t size = words.size_bytes();
    std::string out;
    out.reserve((size + 2) / 3 * 4);
    for (size_t i = 0; i < size; i += 3) {
        const u32 b0 = bytes[i];
        const u32 b1 = i + 1 < size ? bytes[i + 1] : 0;
        const u32 b2 = i + 2 < size ? bytes[i + 2] : 0;
        const u32 v = (b0 << 16) | (b1 << 8) | b2;
        out += Table[(v >> 18) & 63];
        out += Table[(v >> 12) & 63];
        out += i + 1 < size ? Table[(v >> 6) & 63] : '=';
        out += i + 2 < size ? Table[v & 63] : '=';
    }
    return out;
}

/// Writes a shader's SPIR-V to the log in lines of base64 (the mutex of the test held).
void LogSpirv(const char* what, u64 hash) {
    std::vector<u32> words;
    {
        std::scoped_lock lock{g_spirv.mutex};
        if (const auto it = g_spirv.by_hash.find(hash); it != g_spirv.by_hash.end()) {
            words = it->second;
        }
    }
    if (words.empty()) {
        LOG_INFO(Render_Vulkan, "GPU_SHADER_SPIRV {} {:#x}: not kept", what, hash);
        return;
    }
    const std::string text = Base64(words);
    constexpr size_t Line = 3000;
    const size_t parts = (text.size() + Line - 1) / Line;
    for (size_t i = 0; i < parts; ++i) {
        LOG_INFO(Render_Vulkan, "GPU_SHADER_SPIRV {} {:#x} {}/{} {}", what, hash, i + 1, parts,
                 std::string_view{text}.substr(i * Line, Line));
    }
}

s64 (*g_clock)() = nullptr; // SetClockForTest

s64 NowNs() {
    if (g_clock != nullptr) {
        return g_clock();
    }
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

bool UseStageTest() {
    static const bool stages = [] {
        const char* value = std::getenv("SHADPS4_GPU_BENCH");
        return value != nullptr && std::string_view{value} == "stages";
    }();
    return stages;
}

std::string Describe(const ShaderTest& t, int candidate) {
    const auto& [hash, c] = t.candidates[size_t(candidate)];
    const double seconds = double(CensusNs) / 1e9;
    return fmt::format("fs {:#x} (vs {:#x}{}; {:.0f} draws/s, {:.0f} k vertices/s)", hash,
                       c.vs_hash, c.has_gs ? ", GS" : "", double(c.draws) / seconds,
                       double(c.vertices) / seconds / 1000.0);
}

std::string StepName(const ShaderTest& t, const Step& step) {
    switch (step.kind) {
    case Step::Base:
        return "as they are";
    case Step::All:
        return fmt::format("without all {}", t.candidates.size());
    case Step::NoPixels:
        return fmt::format("fs {:#x} without its pixels (vertices only)",
                           t.candidates[size_t(step.candidate)].first);
    case Step::Out:
        return fmt::format("without fs {:#x}", t.candidates[size_t(step.candidate)].first);
    }
    return "?";
}

/// Chooses what to leave out from the count (the mutex held).
void ChooseCandidates(ShaderTest& t) {
    std::vector<std::pair<u64, ShaderCount>> all(t.census.begin(), t.census.end());
    std::vector<std::pair<u64, ShaderCount>> chosen;
    const auto add = [&](size_t up_to) {
        for (const auto& entry : all) {
            if (chosen.size() >= up_to) {
                break;
            }
            if (std::ranges::find_if(chosen, [&](const auto& c) {
                    return c.first == entry.first;
                }) == chosen.end()) {
                chosen.push_back(entry);
            }
        }
    };
    std::ranges::sort(all, [](const auto& a, const auto& b) {
        return a.second.draws > b.second.draws;
    });
    add(MaxCandidates / 2);
    std::ranges::sort(all, [](const auto& a, const auto& b) {
        return a.second.vertices > b.second.vertices;
    });
    add(MaxCandidates);
    t.candidates = std::move(chosen);
    // [B, P0, O0, B, P1, O1, ..., B, All, B]: every step that leaves something out has a step as
    // they are near it on each side. (Without the P steps where the renderer cannot make them.)
    t.steps.clear();
    for (size_t i = 0; i < t.candidates.size(); ++i) {
        t.steps.push_back({Step::Base, -1});
        if (t.pixels_out) {
            t.steps.push_back({Step::NoPixels, int(i)});
        }
        t.steps.push_back({Step::Out, int(i)});
    }
    if (!t.candidates.empty()) {
        t.steps.push_back({Step::Base, -1});
        t.steps.push_back({Step::All, -1});
        t.steps.push_back({Step::Base, -1});
    }
    t.times.clear();
    t.frames.assign(t.steps.size(), 0);

    u64 total_draws = 0;
    u64 total_vertices = 0;
    for (const auto& [hash, count] : t.census) {
        total_draws += count.draws;
        total_vertices += count.vertices;
    }
    const double seconds = double(CensusNs) / 1e9;
    std::string text;
    for (size_t i = 0; i < t.candidates.size(); ++i) {
        text += (i == 0 ? "" : "; ") + Describe(t, int(i));
    }
    LOG_INFO(Render_Vulkan,
             "GPU_SHADER_BENCH: counted {} pixel shaders in the scene passes, {:.0f} draws/s, "
             "{:.0f} k vertices/s; {} steps of {} s follow, for: {}",
             t.census.size(), double(total_draws) / seconds,
             double(total_vertices) / seconds / 1000.0, t.steps.size(),
             ShaderStepNs / 1'000'000'000, text.empty() ? "nothing (no scene draws seen)" : text);
    // What each candidate's draws are made with, and its shaders' SPIR-V.
    for (const auto& [hash, count] : t.candidates) {
        const auto state = t.states.find(hash);
        LOG_INFO(Render_Vulkan, "GPU_SHADER_STATE fs {:#x}: {}", hash,
                 state != t.states.end() ? state->second : std::string{"not seen"});
    }
    for (const auto& [hash, count] : t.candidates) {
        LogSpirv("fs", hash);
        LogSpirv("vs", count.vs_hash);
    }
}

/// The step `now` falls in: -1 counting, steps.size() or more done.
int ShaderStepAt(s64 started, s64 now, s64* into_step = nullptr) {
    const s64 elapsed = now - started;
    if (elapsed < CensusNs) {
        return -1;
    }
    if (into_step != nullptr) {
        *into_step = (elapsed - CensusNs) % ShaderStepNs;
    }
    return int((elapsed - CensusNs) / ShaderStepNs);
}

void ReportShaders(ShaderTest& t) {
    // The game's timer: the one that timed the most.
    const std::vector<StepTime>* times = nullptr;
    double most = -1.0;
    for (const auto& [timer, steps] : t.times) {
        double sum = 0.0;
        for (const auto& step : steps) {
            sum += step.ms;
        }
        if (sum > most) {
            most = sum;
            times = &steps;
        }
    }
    if (times == nullptr || t.candidates.empty()) {
        LOG_INFO(Render_Vulkan, "GPU_SHADER_BENCH: result: no GPU times (SHADPS4_GPU_TIMING=0?) "
                                "or no scene draws");
        return;
    }
    // Per frame shown: a frame's command buffers may be two (one with next to no work, whose
    // time the driver sometimes gives as unusable), so the time a frame is what all of a step's
    // timed command buffers took over the frames presented meanwhile.
    struct PerFrame {
        double total{-1.0};
        double scene{-1.0};
    };
    const double timed_seconds = double(ShaderStepNs - SettleNs) / 1e9;
    std::vector<PerFrame> per(t.steps.size());
    for (size_t k = 0; k < t.steps.size() && k < times->size(); ++k) {
        const u64 frames = t.frames[k];
        const StepTime& st = (*times)[k];
        if (frames > 0 && st.buffers > 0) {
            per[k] = {st.ms / double(frames), st.scene_ms / double(frames)};
        }
        LOG_INFO(Render_Vulkan,
                 "GPU_SHADER_BENCH: step {} ({}): {:.1f} fps, GPU {:.2f} ms a frame, scene "
                 "passes {:.2f} ms ({} command buffers, {} without a usable whole time)",
                 k + 1, StepName(t, t.steps[k]), double(frames) / timed_seconds, per[k].total,
                 per[k].scene, st.buffers, st.unusable);
    }
    // The steps as they are: their spread is how far apart two equal steps come out.
    double low = 1e9;
    double high = 0.0;
    for (size_t k = 0; k < t.steps.size(); ++k) {
        if (t.steps[k].kind == Step::Base && per[k].total >= 0.0) {
            low = std::min(low, per[k].total);
            high = std::max(high, per[k].total);
        }
    }
    // A step's base: the mean of the nearest steps as they are before and after it.
    const auto base = [&](size_t k) -> PerFrame {
        PerFrame before{};
        PerFrame after{};
        for (size_t j = k; j-- > 0;) {
            if (t.steps[j].kind == Step::Base) {
                before = per[j];
                break;
            }
        }
        for (size_t j = k + 1; j < t.steps.size(); ++j) {
            if (t.steps[j].kind == Step::Base) {
                after = per[j];
                break;
            }
        }
        if (before.total < 0.0) {
            return after;
        }
        if (after.total < 0.0) {
            return before;
        }
        return {(before.total + after.total) / 2.0, (before.scene + after.scene) / 2.0};
    };
    LOG_INFO(Render_Vulkan,
             "GPU_SHADER_BENCH: result (ms a frame; steps as they are from {:.2f} to {:.2f}: "
             "smaller differences are noise):",
             low, high);
    const auto saving = [](const PerFrame& b, const PerFrame& x) {
        return b.total >= 0.0 && x.total >= 0.0 ? b.total - x.total : 0.0;
    };
    struct Row {
        size_t pixels_step;
        size_t out_step;
    };
    std::vector<Row> rows;
    size_t all_step = t.steps.size();
    for (size_t k = 0; k < t.steps.size(); ++k) {
        if (t.steps[k].kind == Step::Out) {
            // (no step for the pixels where the renderer cannot make one: steps.size() is none)
            rows.push_back({k > 0 && t.steps[k - 1].kind == Step::NoPixels ? k - 1 : t.steps.size(),
                            k});
        } else if (t.steps[k].kind == Step::All) {
            all_step = k;
        }
    }
    std::ranges::sort(rows, [&](const Row& a, const Row& b) {
        return saving(base(a.out_step), per[a.out_step]) >
               saving(base(b.out_step), per[b.out_step]);
    });
    const auto line = [&](size_t k) {
        if (k >= t.steps.size()) {
            return std::string{"not made on this renderer"};
        }
        const PerFrame b = base(k);
        const PerFrame x = per[k];
        if (b.total < 0.0 || x.total < 0.0) {
            return std::string{"no time measured"};
        }
        return fmt::format("GPU {:.2f} against {:.2f} = {:+.2f} ms, scene passes {:.2f} against "
                           "{:.2f} = {:+.2f} ms",
                           x.total, b.total, x.total - b.total, x.scene, b.scene,
                           x.scene - b.scene);
    };
    for (const Row& row : rows) {
        const int candidate = t.steps[row.out_step].candidate;
        LOG_INFO(Render_Vulkan, "GPU_SHADER_BENCH: {}: without it {}; without its pixels {}",
                 Describe(t, candidate), line(row.out_step), line(row.pixels_step));
    }
    if (all_step < t.steps.size()) {
        LOG_INFO(Render_Vulkan, "GPU_SHADER_BENCH: all {} at once: {}", t.candidates.size(),
                 line(all_step));
    }
}

/// Moves the shader test on: chooses the candidates after the count, sets what is done to the
/// draws, logs each step and the result.
void AdvanceShaderTest() {
    ShaderTest& t = g_shaders;
    const s64 started = t.started.load(std::memory_order_acquire);
    if (started == 0) {
        return;
    }
    const s64 now = NowNs();
    const int step = ShaderStepAt(started, now);
    if (step == t.logged_step.load(std::memory_order_relaxed) &&
        (step < 0 || step < t.num_steps.load(std::memory_order_relaxed))) {
        return; // nothing new (the lock is only taken when the step changes)
    }
    if (const int n = t.num_steps.load(std::memory_order_relaxed);
        n >= 0 && step >= n && t.logged_step.load(std::memory_order_relaxed) == n &&
        now < started + CensusNs + s64(n) * ShaderStepNs + ReportDelayNs) {
        return; // done, the result not due yet
    }
    std::scoped_lock lock{t.mutex};
    if (t.started.load(std::memory_order_relaxed) != started) {
        return; // started again meanwhile
    }
    if (step < 0) {
        t.logged_step.store(-1, std::memory_order_relaxed);
        return;
    }
    if (!t.counted) {
        t.counted = true;
        ChooseCandidates(t);
        t.num_steps.store(int(t.steps.size()), std::memory_order_relaxed);
    }
    const int seen = t.logged_step.load(std::memory_order_relaxed);
    if (size_t(step) < t.steps.size()) {
        const Step& what = t.steps[size_t(step)];
        DrawAction action = DrawAction::Draw;
        u64 hash = 0;
        if (what.kind == Step::NoPixels || what.kind == Step::Out) {
            hash = t.candidates[size_t(what.candidate)].first;
            action = what.kind == Step::Out ? DrawAction::Skip : DrawAction::NoPixels;
        }
        t.hash.store(hash, std::memory_order_relaxed);
        t.action.store(int(action), std::memory_order_relaxed);
        t.all_out.store(what.kind == Step::All, std::memory_order_relaxed);
        if (step != seen) {
            t.logged_step.store(step, std::memory_order_relaxed);
            LOG_INFO(Render_Vulkan, "GPU_SHADER_BENCH: step {} of {}: {}", step + 1,
                     t.steps.size(), StepName(t, what));
        }
        return;
    }
    t.hash.store(0, std::memory_order_relaxed);
    t.action.store(int(DrawAction::Draw), std::memory_order_relaxed);
    t.all_out.store(false, std::memory_order_relaxed);
    if (seen < int(t.steps.size())) {
        t.logged_step.store(int(t.steps.size()), std::memory_order_relaxed);
        LOG_INFO(Render_Vulkan, "GPU_SHADER_BENCH: done; you can move");
    }
    const s64 end = started + CensusNs + s64(t.steps.size()) * ShaderStepNs;
    if (!t.reported && now >= end + ReportDelayNs) {
        t.reported = true;
        ReportShaders(t);
        if (t.renderer != nullptr) {
            LOG_INFO(Render_Vulkan,
                     "GPU_SHADER_BENCH: ended on {}: {} pixel shaders counted, {} of them left "
                     "out in turn, {:.0f} s",
                     t.renderer, t.census.size(), t.candidates.size(),
                     double(now - started) / 1e9);
        }
        t.started.store(0, std::memory_order_release);
    }
}

} // namespace

bool ShaderTestRunning() {
    return g_shaders.started.load(std::memory_order_relaxed) != 0;
}

DrawAction ShaderDraw(bool scene_pass, u64 fs_hash, u64 vs_hash, bool has_gs, u64 vertices) {
    ShaderTest& t = g_shaders;
    const s64 started = t.started.load(std::memory_order_acquire);
    if (started == 0 || !scene_pass) {
        return DrawAction::Draw;
    }
    if (ShaderStepAt(started, NowNs()) < 0) {
        std::scoped_lock lock{t.mutex};
        if (!t.counted) {
            ShaderCount& count = t.census[fs_hash];
            ++count.draws;
            count.vertices += vertices;
            count.vs_hash = vs_hash;
            count.has_gs = count.has_gs || has_gs;
        }
        return DrawAction::Draw;
    }
    if (t.all_out.load(std::memory_order_relaxed)) {
        std::scoped_lock lock{t.mutex};
        return std::ranges::find_if(t.candidates, [&](const auto& c) {
                   return c.first == fs_hash;
               }) != t.candidates.end()
                   ? DrawAction::Skip
                   : DrawAction::Draw;
    }
    const auto action = DrawAction(t.action.load(std::memory_order_relaxed));
    return action != DrawAction::Draw && t.hash.load(std::memory_order_relaxed) == fs_hash
               ? action
               : DrawAction::Draw;
}

int TimingTag() {
    ShaderTest& t = g_shaders;
    const s64 started = t.started.load(std::memory_order_acquire);
    if (started == 0) {
        return -1;
    }
    s64 into = 0;
    const int step = ShaderStepAt(started, NowNs(), &into);
    return step >= 0 && into >= SettleNs ? step : -1;
}

void NoteGpuTime(u32 timer, int tag, double ms, double scene_ms, u64 buffers) {
    ShaderTest& t = g_shaders;
    if (tag < 0 || t.started.load(std::memory_order_acquire) == 0) {
        return;
    }
    std::scoped_lock lock{t.mutex};
    if (size_t(tag) >= t.steps.size()) {
        return;
    }
    auto& steps = t.times[timer];
    steps.resize(t.steps.size());
    if (ms >= 0.0) {
        steps[size_t(tag)].ms += ms;
    } else {
        steps[size_t(tag)].unusable += buffers;
    }
    steps[size_t(tag)].scene_ms += scene_ms;
    steps[size_t(tag)].buffers += buffers;
}

bool WantsShaderState(u64 fs_hash) {
    ShaderTest& t = g_shaders;
    const s64 started = t.started.load(std::memory_order_acquire);
    if (started == 0 || ShaderStepAt(started, NowNs()) >= 0) {
        return false;
    }
    std::scoped_lock lock{t.mutex};
    return !t.counted && !t.states.contains(fs_hash);
}

void NoteShaderState(u64 fs_hash, std::string text) {
    ShaderTest& t = g_shaders;
    std::scoped_lock lock{t.mutex};
    if (!t.counted) {
        t.states.try_emplace(fs_hash, std::move(text));
    }
}

void NoteSpirv(u64 key_hash, std::span<const u32> spirv) {
    std::scoped_lock lock{g_spirv.mutex};
    if (g_spirv.bytes + spirv.size_bytes() > MaxSpirvBytes ||
        g_spirv.by_hash.contains(key_hash)) {
        return;
    }
    g_spirv.by_hash.emplace(key_hash, std::vector<u32>(spirv.begin(), spirv.end()));
    g_spirv.bytes += spirv.size_bytes();
}

void NoteFrame() {
    ShaderTest& t = g_shaders;
    if (t.started.load(std::memory_order_relaxed) == 0) {
        return;
    }
    const int tag = TimingTag();
    if (tag < 0) {
        return;
    }
    std::scoped_lock lock{t.mutex};
    if (size_t(tag) < t.frames.size()) {
        ++t.frames[size_t(tag)];
    }
}

namespace {
void StartShaderTest(const char* renderer, bool pixels_out) {
    ShaderTest& t = g_shaders;
    std::scoped_lock lock{t.mutex};
    t.renderer = renderer;
    t.pixels_out = pixels_out;
    t.counted = false;
    t.reported = false;
    t.census.clear();
    t.candidates.clear();
    t.steps.clear();
    t.times.clear();
    t.frames.clear();
    t.states.clear();
    t.hash.store(0, std::memory_order_relaxed);
    t.action.store(int(DrawAction::Draw), std::memory_order_relaxed);
    t.all_out.store(false, std::memory_order_relaxed);
    t.logged_step.store(-2, std::memory_order_relaxed);
    t.num_steps.store(-1, std::memory_order_relaxed);
    t.started.store(NowNs(), std::memory_order_release);
    LOG_INFO(Render_Vulkan,
             "GPU_SHADER_BENCH: started: {} s counting the scene's pixel shaders, then up to {} "
             "steps of {} s; keep still",
             CensusNs / 1'000'000'000, MaxCandidates * (pixels_out ? 3 : 2) + 3,
             ShaderStepNs / 1'000'000'000);
    if (renderer != nullptr) {
        LOG_INFO(Render_Vulkan, "GPU_SHADER_BENCH: started on {}{}", renderer,
                 pixels_out ? "" : "; no steps without a draw's pixels (it cannot leave them out)");
    }
}
} // namespace

void SetClockForTest(s64 (*now)()) {
    g_clock = now;
}

void Start() {
    // A test shortcut of diagnostics mode only.
    if (!Common::Diagnostics()) {
        return;
    }
    if (!UseStageTest()) {
        StartShaderTest(nullptr, true);
        return;
    }
    const auto now = std::chrono::steady_clock::now().time_since_epoch().count();
    g_step.store(-1, std::memory_order_relaxed);
    g_started.store(now, std::memory_order_release);
    LOG_INFO(Render_Vulkan, "GPU_BENCH: started: {} steps of {} s; keep still", std::size(Steps),
             StepLength.count());
}

void StartOn(const char* renderer, bool can_discard_pixels) {
    if (!Common::Diagnostics()) {
        return;
    }
    StartShaderTest(renderer, can_discard_pixels);
}

Mode Current() {
    AdvanceShaderTest();
    const s64 started = g_started.load(std::memory_order_acquire);
    if (started == 0) {
        return Mode::Normal;
    }
    const auto elapsed = std::chrono::steady_clock::now().time_since_epoch() -
                         std::chrono::steady_clock::duration{started};
    const int step = static_cast<int>(elapsed / StepLength);
    const int total = static_cast<int>(std::size(Steps));
    int seen = g_step.load(std::memory_order_relaxed);
    if (step != seen && g_step.compare_exchange_strong(seen, step)) {
        if (step < total) {
            LOG_INFO(Render_Vulkan, "GPU_BENCH: step {} of {}: {}", step + 1, total,
                     Name(Steps[step]));
        } else {
            LOG_INFO(Render_Vulkan, "GPU_BENCH: done");
            // Only this run's start: a Start() made meanwhile is kept.
            s64 expected = started;
            g_started.compare_exchange_strong(expected, 0, std::memory_order_acq_rel);
        }
    }
    return step < total ? Steps[step] : Mode::Normal;
}

} // namespace GpuBench

} // namespace Vulkan
