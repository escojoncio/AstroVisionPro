// VPKEngine: the only renderer on visionOS (see vpkengine_renderer.h).
#include "vpkengine_renderer.h"

#import <Metal/Metal.h>
#include <mach/mach.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <functional>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include <fmt/ranges.h>
#include "common/elf_info.h"
#include "common/logging/log.h"
#include "common/path_util.h"
#include "core/libraries/videoout/buffer.h"
#include "core/memory.h"
#include "vpkengine_mirror.h"
#include "vpkengine_census.h"
#include "vpkengine_xr.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/amdgpu/pm4_exec.h"
#include "video_core/amdgpu/reg_audit.h"
#include "video_core/amdgpu/regs.h"
#include "video_core/amdgpu/resource.h"
#include "video_core/page_manager.h"
#include "vp4gpu/core/device.h"
#include "vp4gpu/metal/metal_backend.h"
#include "vpps4/fetch.h"
#include "vpps4/formats.h"
#include "vpps4/renderer.h"
#include "vpps4/scheduler.h"
#include "vp4gpu/core/submit_policy.h"
#include "vpps4/report.h"

namespace VpkengineRenderer {
namespace {
void PrewarmCompose(void* nativeDevice);  // (defined with PresentState)

// Guest addresses are host addresses. Buffers alias guest memory through windows of this size
// (aligned), cut down to the mapped part around the address: one huge mapping as a single
// no-copy MTLBuffer can exceed the device's maximum buffer length.
constexpr u64 kWindow = 64ull << 20;

// The mapped span of [from, to) that contains `address`, walking the VM entries (guest memory is
// many entries with different protections); false if `address` is not mapped.
bool mappedSpan(u64 address, u64 from, u64 to, u64& begin, u64& end) {
    begin = end = address;
    vm_address_t at = vm_address_t(from);
    bool found = false;
    while (at < to) {
        vm_address_t base = at;
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &base, &size, VM_REGION_BASIC_INFO_64,
                         reinterpret_cast<vm_region_info_t>(&info), &count, &object) != KERN_SUCCESS)
            break;
        // (reserved, never-readable address space is not memory to alias; pages shadPS4 merely
        // protects to watch them are readable at most and stay in)
        const bool usable = (info.max_protection & VM_PROT_READ) != 0;
        if (!usable) {
            if (found) break;
            if (base + size > address && base <= address) return false;
            at = base + size;
            continue;
        }
        if (base > at) {  // a hole before the next entry
            if (found) break;
            if (base > address) return false;
        }
        const u64 lo = std::max<u64>(base, from), hi = std::min<u64>(base + size, to);
        if (!found) {
            if (address >= lo && address < hi) {
                found = true;
                begin = lo;
                end = hi;
            }
        } else if (lo == end) {
            end = hi;
        } else {
            break;
        }
        at = base + size;
    }
    if (!found) return false;
    // Extend backwards: entries before `address` inside the window, contiguous with `begin`.
    for (u64 probe = begin; probe > from;) {
        vm_address_t base = vm_address_t(probe - 1);
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info{};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &base, &size, VM_REGION_BASIC_INFO_64,
                         reinterpret_cast<vm_region_info_t>(&info), &count, &object) != KERN_SUCCESS ||
            base > probe - 1 || base + size < probe || !(info.max_protection & VM_PROT_READ))
            break;
        begin = std::max<u64>(base, from);
        probe = begin;
    }
    return true;
}

// mappedSpan answers cached: it walks the VM map with vm_region_64 syscalls (often tens per call)
// and is asked for every buffer binding of every draw. The span of an address inside a window is
// unique, so (window, span) pairs are kept until the GPU mappings change (MapMemory/UnmapMemory).
struct SpanCache {
    struct Entry {
        u64 from = 0, to = 0, begin = 0, end = 0;
        void* mirror = nullptr;  // the second mapping of [begin, end) the GPU buffers alias (null: none)
    };
    std::mutex m;
    std::array<Entry, 128> entries{};
    unsigned used = 0, next = 0, last = 0;
    u64 gen = 0;  // bumped by clear(): a span looked up before it is not inserted after it
    // The same count readable without the lock: what was checked readable at one value of it is
    // still mapped at the same value (the draw adapter keeps fetch subroutines by it).
    std::atomic<u64> mapGen{0};
    void clear() {
        std::scoped_lock l{m};
        used = next = last = 0;
        ++gen;
        mapGen.store(gen, std::memory_order_release);
    }
};
SpanCache& spanCache() {
    static SpanCache& c = *new SpanCache;
    return c;
}

// Whether any page of [begin, end) is protected for the renderer (owned or watched ranges): set by the
// rasterizer, which keeps those tables.
std::atomic<bool (*)(void*, u64, u64)> gWatchProbe{nullptr};
std::atomic<void*> gWatchProbeContext{nullptr};
bool spanHasWatches(u64 begin, u64 end) {
    auto* probe = gWatchProbe.load(std::memory_order_acquire);
    return probe && probe(gWatchProbeContext.load(std::memory_order_acquire), begin, end);
}

bool cachedSpan(u64 address, u64 from, u64 to, u64& begin, u64& end, void*& mirror) {
    SpanCache& c = spanCache();
    u64 gen0 = 0;
    {
        std::scoped_lock l{c.m};
        gen0 = c.gen;
        const auto hit = [&](const SpanCache::Entry& x) {
            return x.from == from && x.to == to && address >= x.begin && address < x.end;
        };
        if (c.used && hit(c.entries[c.last])) {
            begin = c.entries[c.last].begin;
            end = c.entries[c.last].end;
            mirror = c.entries[c.last].mirror;
            return true;
        }
        for (unsigned k = 0; k < c.used; ++k)
            if (hit(c.entries[k])) {
                c.last = k;
                begin = c.entries[k].begin;
                end = c.entries[k].end;
                mirror = c.entries[k].mirror;
                return true;
            }
    }
    if (!mappedSpan(address, from, to, begin, end)) return false;  // (misses are not cached)
    // The span's mirror (made once per span, checked again whenever the span is looked up afresh:
    // every ~8 ms at most, see Engine::submit).
    mirror = GuestMirror(begin, end);
    if (!mirror && spanHasWatches(begin, end)) return true;  // (looked up again next time: the mirror may come)
    std::scoped_lock l{c.m};
    if (c.gen != gen0) return true;  // the map changed meanwhile: use it this once, keep it out
    const unsigned k = c.used < c.entries.size() ? c.used++ : (c.next++ % unsigned(c.entries.size()));
    c.entries[k] = {from, to, begin, end, mirror};
    c.last = k;
    return true;
}

// Bytes readable from `address` on (up to `want`), 0 if it is not mapped.
u64 readable(u64 address, u64 want) {
    const u64 from = address & ~(kWindow - 1);
    u64 begin, end;
    void* mirror = nullptr;
    if (!cachedSpan(address, from, from + kWindow, begin, end, mirror)) return 0;
    return std::min<u64>(want, end - address);
}

// One line on why the region hook has no span for `address`: whether the emulator's own map knows it
// (a relocated fixed mapping would show here), the span and its mirror / watches, or the nearest regions.
std::string ExplainAddress(u64 address) {
    std::string out = fmt::format("addr {:#x}: emulator map {}", address,
                                  Core::Memory::Instance()->IsValidMapping(address, 1) ? "valid" : "invalid");
    const u64 from = address & ~(kWindow - 1);
    u64 begin = 0, end = 0;
    void* mirror = nullptr;
    if (address >= 0x10000 && cachedSpan(address, from, from + kWindow, begin, end, mirror)) {
        out += fmt::format("; host span [{:#x}, {:#x}) mirror={} watched={}", begin, end, mirror != nullptr,
                           spanHasWatches(begin, end));
        return out;
    }
    // Not mapped for the host: the nearest VM entries around it.
    vm_address_t base = vm_address_t(address);
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &base, &size, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info),
                     &count, &object) == KERN_SUCCESS)
        out += fmt::format("; next host region [{:#x}, {:#x}) prot {}/{}", u64(base), u64(base) + u64(size), int(info.protection),
                           int(info.max_protection));
    else
        out += "; no host region above";
    if (address >= (1ull << 20)) {
        // (the entry below: asked for from a bit lower; a hit at or above `address` means nothing is below nearby)
        vm_address_t b2 = vm_address_t(address - std::min<u64>(address, 1ull << 30));
        vm_size_t s2 = 0;
        count = VM_REGION_BASIC_INFO_COUNT_64;
        object = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &b2, &s2, VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info),
                         &count, &object) == KERN_SUCCESS && u64(b2) < address)
            out += fmt::format("; a host region [{:#x}, {:#x}) within 1 GiB below", u64(b2), u64(b2) + u64(s2));
    }
    return out;
}

// MSL from the shader translator, as the Metal backend takes it (msl.h argument contract).
vp4gpu::metal::MslShader toMetal(const vp4msl::MslShader& s) {
    vp4gpu::metal::MslShader m;
    m.source = s.source;
    m.entry = "vp_main";
    m.argumentBufferIndex = 0;
    m.threadsPerGroup = s.workgroupSize;
    m.colorOutputs = s.colorOutputs;
    for (const vp4msl::Argument& a : s.arguments)
        m.arguments.push_back({vp4gpu::BindKind(uint8_t(a.kind) + 1), uint16_t(a.index), a.offset});
    return m;
}

void flushLeftOut();  // defined below, with the counters it drains

// The engine: VPKEngine's Metal backend, device and PS4 renderer, shared by the rasterizer (GPU
// thread) and the presenter. Everything that records goes under `lock`.
struct Engine {
    // Recursive: a CPU access to memory an image on the GPU is ahead of faults inside code that
    // holds the lock already (a DMA done on the CPU); the fault handler writes the image back.
    std::recursive_mutex lock;
    vp4gpu::metal::ShaderTable shaders;
    std::unique_ptr<vp4gpu::metal::MetalBackend> backend;
    std::unique_ptr<vp4gpu::Device> device;
    std::unique_ptr<vpps4::Renderer> renderer;
    // When recorded work goes to the GPU, and how DMA / GDS / labels stay ordered with it.
    std::unique_ptr<vpps4::Scheduler> scheduler;
    // Watchdog: submits recorded work that nothing else asked for once the policy says so (a label
    // waiting too long, a frame open too long). Takes `lock`, sleeps on watchCv.
    std::thread watchdog;
    std::condition_variable_any watchCv;  // (the engine lock is recursive: condition_variable takes only std::mutex)
    std::atomic<u64> submits{0};
    std::atomic<unsigned> errorLines{0};
    // Set by the rasterizer: page watches (renderer hooks watchWrites / watchOwned).
    std::function<void(u64, u64)> watchWrites;
    std::function<void(u64, u64, bool)> watchOwned;
    // The vertex shaders' fetch subroutines, kept so a draw does not walk the shader and its
    // subroutine again: where the subroutine's address comes from (FetchAddressMemo), and its
    // words with the mapping generation they were checked readable at (the content is compared
    // each draw: the title may rewrite shader memory).
    vpps4::FetchAddressMemo fetchAddresses;
    struct FetchBody {
        u64 address = 0, generation = ~u64(0);
        u32 words = 0;
        std::array<uint32_t, 512> code;
    };
    std::array<FetchBody, 32> fetchBodies{};
    // Invalidations come from the page-fault handler: queued without the engine lock (it may be
    // held for long, or by the faulting thread itself) and applied before the next command.
    std::atomic_flag pendingLock = ATOMIC_FLAG_INIT;
    std::vector<std::pair<u64, u64>> pending;
    // Too many ranges queued (the engine lock was held for long): they are not kept one by one, the
    // whole address space is invalidated when they are applied. Dropping them would leave stale
    // textures and owners.
    bool pendingAll = false;
    void queueInvalidate(u64 a, u64 n) {
        while (pendingLock.test_and_set(std::memory_order_acquire)) {}
        if (pendingAll) {
            // (already everything)
        } else if (pending.size() < 65536) {
            pending.push_back({a, n});
        } else {
            pendingAll = true;
            pending.clear();
            pending.shrink_to_fit();
        }
        pendingLock.clear(std::memory_order_release);
    }
    void applyPending() {
        while (pendingLock.test_and_set(std::memory_order_acquire)) {}
        std::vector<std::pair<u64, u64>> work;
        work.swap(pending);
        const bool all = pendingAll;
        pendingAll = false;
        pendingLock.clear(std::memory_order_release);
        if (!renderer) return;
        if (all) {
            // Which ranges the CPU wrote is unknown: images ahead of memory are written back (and the GPU waited
            // for) first, so marking everything CPU-written does not drop the content only they hold.
            if (scheduler) syncForDma(0, ~u64(0));
            else renderer->syncToMemory(0, ~u64(0));
            renderer->invalidate(0, ~u64(0));
        }
        for (auto [a, n] : work) renderer->invalidate(a, n);
    }
    bool failed = false;
    u64 dmaUnsynced = 0, dmaSynced = 0;  // DMA packets done on the CPU without / after a GPU wait

    // CPU time of the GPU thread, in ns, printed every ~2 s (VPKENGINE_GPU cpu:). Atomics: the
    // presenter submits too, and draw timers stop after the engine lock is released.
    using Clock = std::chrono::steady_clock;
    std::atomic<u64> adapterNs{0}, adapterCalls{0};
    Clock::time_point lastReport = Clock::now();
    Clock::time_point lastSpanClear = Clock::now();
    static u64 nsSince(Clock::time_point t) {
        return u64(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t).count());
    }
    struct Timer {
        std::atomic<u64>& to;
        Clock::time_point t0 = Clock::now();
        ~Timer() { to.fetch_add(nsSince(t0), std::memory_order_relaxed); }
    };
    static double msNow() {
        return std::chrono::duration<double, std::milli>(Clock::now().time_since_epoch()).count();
    }
    // Work was recorded: the watchdog learns when the frame opened.
    void noteWork() {
        if (scheduler && scheduler->noteWork()) watchCv.notify_one();
    }
    // CPU-side DMA over guest [a, +n) (and [b, +m)): waits only for the frames that touch it (a partial
    // fence), submitting the recorded frame first only when the overlap is in it.
    void syncForDma(u64 a, u64 n, u64 b = 0, u64 m = 0) {
        // Images ahead of the memory the CPU is about to read or write are written back first (the
        // copies it records count as queued GPU work on those ranges: submitted and waited for below).
        const bool written = renderer->syncToMemory(a, n);
        const bool writtenB = m && renderer->syncToMemory(b, m);
        if (scheduler->syncCpu(a, n, vp4gpu::SubmitReason::Dma, b, m) || written || writtenB) ++dmaSynced;
        else ++dmaUnsynced;
    }
    void watchdogLoop() {
        std::unique_lock l{lock};
        for (;;) {
            const double next = scheduler ? scheduler->nextCheckMs() : -1.0;
            if (next < 0) {
                watchCv.wait(l);
            } else if (next > 0) {
                watchCv.wait_for(l, std::chrono::microseconds(u64(next * 1000.0) + 100));
            } else if (!scheduler->tick()) {
                watchCv.wait_for(l, std::chrono::milliseconds(1));
            }
        }
    }
    void report() {
        const double s = std::chrono::duration<double>(Clock::now() - lastReport).count();
        if (s < 2.0 || !renderer) return;
        lastReport = Clock::now();
        const vpps4::CpuTimes t = renderer->takeCpuTimes();
        auto msps = [&](u64 ns) { return double(ns) / 1e6 / s; };
        auto take = [](std::atomic<u64>& a) { return a.exchange(0, std::memory_order_relaxed); };
        const u64 calls = take(adapterCalls), adapter = take(adapterNs);
        LOG_INFO(Render_Vulkan,
                 "VPKENGINE_GPU cpu: draw_adapter {:.1f} ms/s, vpps4.draw {:.1f}, shader lookup {:.1f}, bind {:.1f}, "
                 "pipeline request {:.1f}, frame compile+submit {:.1f} ({:.0f} submits/s, {:.0f} empty/s), "
                 "draws {:.0f}/s, per-draw {:.2f} us adapter / {:.2f} us vpps4, user data reused {:.0f}/s, aligned copies reused {:.0f}/s",
                 msps(adapter), t.drawMs / s, t.shaderMs / s, t.bindMs / s, t.pipelineMs / s, t.submitMs / s,
                 double(t.submits) / s, double(t.emptySubmits) / s, double(calls) / s,
                 calls ? double(adapter) / 1e3 / double(calls) : 0.0, t.calls ? t.drawMs * 1e3 / double(t.calls) : 0.0,
                 double(t.userDataReused) / s, double(t.alignedCopyReused) / s);
        if (scheduler) LOG_INFO(Render_Vulkan, "VPKENGINE_GPU {}", scheduler->takeSummary());
    }

    static constexpr u64 kEvery = 120;  // per-frame lines of the core every kEvery submits
    void log(const std::string& line) {
        const bool error = line.rfind("gpu.err", 0) == 0 || line.rfind("vpps4.shader error", 0) == 0;
        if (error) {
            if (errorLines++ < 200) LOG_WARNING(Render_Vulkan, "VPKENGINE_GPU {}", line);
            return;
        }
        const u64 f = submits.load();
        if (line.rfind("gpu.", 0) == 0 && line.rfind("gpu.metal", 0) != 0 && f != 0 && f % kEvery != 1) return;
        LOG_INFO(Render_Vulkan, "VPKENGINE_GPU {}", line);
    }

    bool start() {
        if (renderer || failed) return renderer != nullptr;
        // One GPU frame per presented picture (vpps4::Scheduler accumulates the ~15 Liverpool command
        // buffers of a picture), so two frames in flight (the headset's compose included) are enough and
        // bound the latency; vpps4's upload rings (8) cover them.
        vp4gpu::metal::MetalOptions options;
        options.framesInFlight = 2;
        // What the engine keeps between runs, in the cache folder the app points the emulator at
        // (the VPS4 folder's Cachés), one folder per game: the Metal pipeline archive, the
        // translated shaders and the list of pipelines built (compiled ahead at the next start).
        const std::string serial{Common::ElfInfo::Instance().GameSerial()};
        const std::filesystem::path cacheDir =
            Common::FS::GetUserPath(Common::FS::PathType::CacheDir) / "vpkengine" / (serial.empty() ? "unknown" : serial);
        {
            std::error_code ec;
            std::filesystem::create_directories(cacheDir / "metal", ec);
            if (!ec) options.cacheRoot = cacheDir / "metal";
        }
        backend = std::make_unique<vp4gpu::metal::MetalBackend>(shaders, [this](const std::string& l) { log(l); },
                                                               options);
        if (!backend->ok()) {
            failed = true;
            LOG_CRITICAL(Render_Vulkan, "VPKENGINE_GPU no Metal device: nothing can be drawn");
            return false;
        }
        // What the host can sample natively decides the texture plans (BC is absent on visionOS): set before
        // the first draw builds one.
        {
            vpps4::FormatCaps fc;
            fc.bc = backend->caps().bc;
            vpps4::setFormatCaps(fc);
        }
        device = std::make_unique<vp4gpu::Device>(*backend, 2, [this](const std::string& l) { log(l); });
        vpps4::Hooks hooks;
        hooks.region = [](uint64_t address, uint64_t size, vpps4::GuestRegion& out) {
            if (address < 0x10000) return false;
            const u64 from = address & ~(kWindow - 1);
            const u64 to = std::max(from + kWindow, (address + size + kWindow - 1) & ~(kWindow - 1));
            u64 begin, end;
            void* mirror = nullptr;
            if (!cachedSpan(address, from, to, begin, end, mirror) || address + size > end) return false;
            // No mirror: the buffers would alias the guest addresses, which are page-protected where
            // an image is ahead of memory or a texture source is watched. A buffer over protected
            // pages faults or reads garbage: the span is not offered at all (draws using it are
            // skipped and counted) until a mirror exists.
            if (!mirror && spanHasWatches(begin, end)) return false;
            // With a mirror the GPU buffers alias it and the guest addresses may be page-protected
            // (CPU write / read detection); without one they alias the guest addresses and nothing
            // is protected (the renderer then finds CPU writes by content).
            out = {begin, end - begin, mirror ? mirror : reinterpret_cast<void*>(begin), mirror != nullptr};
            return true;
        };
        hooks.explainAddress = [](uint64_t address) { return ExplainAddress(address); };
        hooks.shader = [this](uint64_t id, vp4ir::Stage, const vp4msl::MslShader& s) { shaders.add(id, toMetal(s)); };
        hooks.log = [this](const std::string& l) { log(l); };
        hooks.watchWrites = [this](uint64_t a, uint64_t n) {
            if (watchWrites) watchWrites(a, n);
        };
        hooks.watchOwned = [this](uint64_t a, uint64_t n, bool on) {
            if (watchOwned) watchOwned(a, n, on);
        };
        // Views of images (another format of the same texel size, a layer range, a cube / array):
        // lazily resolved handles of the Metal backend.
        hooks.view = [this](const vpps4::ViewRequest& r) -> vp4gpu::TextureId {
            vp4gpu::metal::MetalBackend::ViewDesc d;
            d.type = r.type;
            d.array = r.array;
            d.format = r.format;
            d.baseLayer = r.baseLayer;
            d.layers = r.layers;
            return backend->createView(r.base, d);
        };
        hooks.destroyView = [this](vp4gpu::TextureId v) { backend->destroyView(v); };
        // Opt-in (VPK_SUBMIT_THREAD=1): frame encoding on its own thread. Not on by default: the Metal
        // backend was written for one thread that creates resources and submits.
        if (const char* t = std::getenv("VPK_SUBMIT_THREAD"); t && *t && *t != '0') device->startSubmitThread(2);
        // What vpps4 skips / approximates / cannot translate goes to the census.
        vpps4::setReportSink([](void*, const char* cat, const char* key, const char* detail, u64 count) {
            Census::NoteN(cat ? cat : "vpps4", key ? key : "", detail ? detail : "", count);
        });
        renderer = std::make_unique<vpps4::Renderer>(*device, std::move(hooks));
        renderer->setSummaryEvery(kEvery);
        scheduler = std::make_unique<vpps4::Scheduler>(*renderer, *device, vp4gpu::SubmitPolicy{}, [] { return msNow(); });
        scheduler->setSubmitHook([this] {
            ++submits;
            // Guest mappings can change without Map/UnmapMemory (a munmap or protection change of
            // the title's): spans are looked up again (vm_region syscalls, tens per span). Once per
            // ~8 ms rather than at each submit.
            if (nsSince(lastSpanClear) > 8'000'000) {
                spanCache().clear();
                lastSpanClear = Clock::now();
            }
            if (submits % kEvery == 1)
                LOG_INFO(Render_Vulkan, "VPKENGINE_GPU dma: {} packets without a GPU wait, {} after one (so far)",
                         dmaUnsynced, dmaSynced);
            renderer->drainOcclusion(false);  // ZPASS_DONE results of frames that finished
            flushLeftOut();
            report();
        });
        watchdog = std::thread([this] { watchdogLoop(); });
        watchdog.detach();
        // MSAA: the game's targets keep their sample count up to the app's limit (SHADPS4_MAX_MSAA,
        // 1/2/4, default 4; Apple GPUs stop at 4). 1 turns it off: the targets become single-sample
        // and the game's resolves become copies. Foveation (SHADPS4_GAME_FOVEATION=1, default off)
        // is exclusive with MSAA: a pass that has both draws without foveation.
        int maxMsaa = 4;
        if (const char* v = std::getenv("SHADPS4_MAX_MSAA")) maxMsaa = std::clamp(std::atoi(v), 1, 4);
        renderer->setMaxSamples(uint8_t(maxMsaa));
        const char* fov = std::getenv("SHADPS4_GAME_FOVEATION");
        renderer->setFoveation(fov && std::atoi(fov) != 0);
        renderer->setCacheRoot(cacheDir / "vpps4");
        LOG_INFO(Render_Vulkan, "VPKENGINE_GPU persistent caches in {}", cacheDir.string());
        LOG_INFO(Render_Vulkan, "VPKENGINE_GPU renderer on (VPKEngine draws everything in Metal; no Vulkan device)");
        // Off the first frame's path: the headset compositing shader is compiled meanwhile.
        if (VpkengineXr::Available()) PrewarmCompose(backend->nativeDevice());
        return true;
    }

    // Hands the recorded work to the GPU now (the picture is presented).
    void present() {
        if (scheduler) scheduler->present();
    }
};

Engine& engine() {
    static Engine& e = *new Engine;  // never destroyed: the rasterizer may outlive statics
    return e;
}

// The program of a stage as the renderer wants it: code (whole binary), user data, address.
void fillStage(vpps4::Stage& st, const AmdGpu::ShaderProgram& program) {
    const auto params = AmdGpu::GetParams(program);
    st.code = params.code;
    st.address = reinterpret_cast<uint64_t>(params.code.data());
    std::copy_n(program.user_data.begin(), 16, st.userData.begin());
    st.userSgprs = uint8_t(program.settings.num_user_regs);
}

// CB_COLORn as VPKEngine's colour target (write mask left at its default).
vpps4::ColorTarget colorTarget(const AmdGpu::Regs& regs, unsigned i) {
    const auto& cb = regs.color_buffers[i];
    vpps4::ColorTarget c;
    c.address = cb.Address();
    c.width = cb.Pitch();
    c.height = cb.Height();
    c.pitch = cb.Pitch();
    c.format = uint8_t(cb.info.format);
    c.numberType = uint8_t(cb.info.number_type);
    c.compSwap = uint8_t(cb.info.comp_swap);
    c.tileMode = cb.info.linear_general ? 31 : uint8_t(cb.attrib.tile_mode_index);
    c.sliceStart = uint16_t(cb.BaseSlice());
    c.sliceCount = uint16_t(cb.NumSlices());
    c.samples = uint8_t(cb.NumSamples());  // colour fragments (EQAA: what the surface stores)
    c.coverage = uint8_t(1u << cb.attrib.num_samples_log2);
    c.fastClear = cb.info.fast_clear;
    c.clearWord = {cb.clear_word0, cb.clear_word1};
    return c;
}

// Counts of draws left out before the renderer, by reason (logged the first time each). Reasons are
// literals: a small table keyed by the literal's address, lock-free counters; the census gets the
// counts once per submit (flushLeftOut).
struct LeftOut {
    std::atomic<const char*> why{nullptr};
    std::atomic<u64> total{0}, reported{0};
};
constexpr size_t kLeftOut = 64;
LeftOut gLeftOut[kLeftOut];
std::atomic<size_t> gLeftOutUsed{0};

void leftOut(const char* why) {
    size_t n = gLeftOutUsed.load(std::memory_order_acquire);
    for (size_t i = 0; i < n; ++i)
        if (gLeftOut[i].why.load(std::memory_order_acquire) == why) {
            const u64 c = gLeftOut[i].total.fetch_add(1, std::memory_order_relaxed) + 1;
            if (c == 1000 || c == 10000 || c == 100000 || c % 1000000 == 0)
                LOG_INFO(Render_Vulkan, "VPKENGINE_GPU draws left out: {} x{}", why, c);
            return;
        }
    // A reason not seen yet (or the table raced): claim a slot under a lock, once per reason.
    static std::mutex m;
    std::scoped_lock l{m};
    n = gLeftOutUsed.load(std::memory_order_acquire);
    for (size_t i = 0; i < n; ++i)
        if (gLeftOut[i].why.load(std::memory_order_acquire) == why) {
            gLeftOut[i].total.fetch_add(1, std::memory_order_relaxed);
            return;
        }
    if (n == kLeftOut) {  // (full: counted the slow way, straight to the census)
        Census::Note("draw-skip", why);
        return;
    }
    gLeftOut[n].total.store(1, std::memory_order_relaxed);
    gLeftOut[n].why.store(why, std::memory_order_release);
    gLeftOutUsed.store(n + 1, std::memory_order_release);
    LOG_INFO(Render_Vulkan, "VPKENGINE_GPU first draw left out: {}", why);
}

// The reasons counted since the last call, to the census in one add each.
void flushLeftOut() {
    const size_t n = gLeftOutUsed.load(std::memory_order_acquire);
    for (size_t i = 0; i < n; ++i) {
        LeftOut& e = gLeftOut[i];
        const u64 t = e.total.load(std::memory_order_relaxed);
        const u64 r = e.reported.exchange(t, std::memory_order_relaxed);
        if (t > r) Census::NoteN("draw-skip", e.why.load(std::memory_order_acquire), {}, t - r);
    }
}

// Context registers the draw path reads (everything else that is set away from its reset value is
// reported once per value to the census, category "reg": a register the title uses and nothing here
// honours). Whole registers: a partly read one (e.g. PA_SU_SC_MODE_CNTL) counts as read.
void auditContextRegs(const AmdGpu::Regs& regs) {
    static std::mutex m;
    std::unique_lock l{m, std::try_to_lock};
    if (!l.owns_lock()) return;
    static AmdGpu::RegAudit::Auditor* auditor = [] {
        auto defaults = std::make_unique<AmdGpu::Regs>();
        defaults->SetDefaults();
        auto* a = new AmdGpu::RegAudit::Auditor(&defaults->reg_array[AmdGpu::RegAudit::kContextBase]);
        const auto base = reinterpret_cast<const u8*>(defaults->reg_array.data());
        auto consume = [&](const void* field, size_t bytes) {
            a->Consume(u32((reinterpret_cast<const u8*>(field) - base) / sizeof(u32)), u32((bytes + 3) / sizeof(u32)));
        };
#define VPK_READ(f) consume(&defaults->f, sizeof(defaults->f))
        VPK_READ(stage_enable); VPK_READ(color_buffers); VPK_READ(color_control); VPK_READ(color_target_mask);
        VPK_READ(color_shader_mask); VPK_READ(blend_control); VPK_READ(blend_constants); VPK_READ(depth_buffer);
        VPK_READ(depth_view); VPK_READ(depth_render_control); VPK_READ(depth_clear); VPK_READ(stencil_clear);
        VPK_READ(depth_control); VPK_READ(stencil_control); VPK_READ(stencil_ref_front); VPK_READ(stencil_ref_back);
        VPK_READ(viewports[0]); VPK_READ(screen_scissor); VPK_READ(polygon_control); VPK_READ(primitive_type);
        VPK_READ(num_indices); VPK_READ(num_instances); VPK_READ(index_buffer_type); VPK_READ(index_base_address);
        VPK_READ(index_offset); VPK_READ(max_index_size); VPK_READ(vgt_instance_step_rate_0);
        VPK_READ(vgt_instance_step_rate_1); VPK_READ(ps_input_addr); VPK_READ(color_export_format);
        VPK_READ(ps_inputs);
        // num_interp is a bit-field: the word after ps_input_addr and its padding word.
        consume(reinterpret_cast<const u8*>(&defaults->ps_input_addr) + sizeof(defaults->ps_input_addr) + 4, 4);
#undef VPK_READ
        return a;
    }();
    auditor->Check(&regs.reg_array[AmdGpu::RegAudit::kContextBase], [](u32 reg, u32 value) {
        if (reg == 0) return Census::Note("reg", "audit table full");
        Census::Note("reg", fmt::format("{:#06x}={:#010x}", reg, value), "context register set, not read by the renderer");
    });
}

// ES/LS (geometry / tessellation) draws are left out: log what they are, so the path can be
// built from evidence (which colour target they write, whether a GS amplifies to layers, and
// the ES/GS/copy-VS code words for .lift tests). Distinct (stages, CB0) pairs, first 8 only;
// each program's words once.
void describeGeometryDraw(const AmdGpu::Regs& regs) {
    static std::mutex m;
    static std::set<std::pair<u32, u64>> seen;
    static std::set<u64> dumped;
    std::scoped_lock l{m};
    const u32 stages = u32(regs.stage_enable.raw);
    const u64 cb0 = regs.color_buffers[0] ? u64(regs.color_buffers[0].Address()) : 0ull;
    if (seen.size() >= 8 || !seen.insert({stages, cb0}).second) return;
    u32 gsMode = 0, gsInst = 0, outPrim = 0;
    std::memcpy(&outPrim, &regs.vgt_gs_out_prim_type, sizeof outPrim);
    std::memcpy(&gsMode, &regs.vgt_gs_mode, sizeof gsMode);
    std::memcpy(&gsInst, &regs.vgt_gs_instance_cnt, sizeof gsInst);
    std::string cbs;
    for (unsigned i = 0; i < 8; ++i) {
        const auto& cb = regs.color_buffers[i];
        if (!cb) continue;
        cbs += fmt::format(" cb{}@{:#x} {}x{} pitch {} slices {}+{} fmt {}/{}", i, u64(cb.Address()), u32(cb.Pitch()),
                           u32(cb.Height()), u32(cb.Pitch()), u32(cb.BaseSlice()), u32(cb.NumSlices()),
                           u32(cb.info.format), u32(cb.info.number_type));
    }
    LOG_INFO(Render_Vulkan,
             "VPKENGINE_GEOM stages {:#x} (ls {} hs {} es {} gs {} vs {}) gs_mode {:#x} gs_instances {:#x} out_prim {} "
             "max_vert {} esgs_item {} gsvs_item {} vert_item {}/{}/{}/{} prim {}{}",
             stages, u32(regs.stage_enable.ls_en), u32(regs.stage_enable.hs_en), u32(regs.stage_enable.es_en),
             u32(regs.stage_enable.gs_en), u32(regs.stage_enable.vs_en), gsMode, gsInst,
             outPrim, u32(regs.vgt_gs_max_vert_out), u32(regs.vgt_esgs_ring_itemsize),
             u32(regs.vgt_gsvs_ring_itemsize), u32(regs.vgt_gs_vert_itemsize[0]), u32(regs.vgt_gs_vert_itemsize[1]),
             u32(regs.vgt_gs_vert_itemsize[2]), u32(regs.vgt_gs_vert_itemsize[3]), u32(regs.primitive_type), cbs);
    auto dump = [&](const char* name, const AmdGpu::ShaderProgram& prog) {
        if (!prog.Address<u32*>()) return;
        const auto params = AmdGpu::GetParams(prog);
        const u64 key = reinterpret_cast<u64>(params.code.data());
        LOG_INFO(Render_Vulkan, "VPKENGINE_GEOM {} @{:#x} user_sgprs {} words {} user_data {:08x}", name, key,
                 u32(prog.settings.num_user_regs), params.code.size(),
                 fmt::join(std::span(prog.user_data.data(), 16), " "));
        if (!dumped.insert(key).second) return;
        for (size_t at = 0; at < params.code.size(); at += 128)
            LOG_INFO(Render_Vulkan, "VPKENGINE_GEOM {} @{:#x} code@{}: {:08x}", name, key, at,
                     fmt::join(params.code.subspan(at, std::min<size_t>(128, params.code.size() - at)), " "));
    };
    if (regs.stage_enable.ls_en) dump("ls", regs.ls_program);
    if (regs.stage_enable.hs_en) dump("hs", regs.hs_program);
    if (regs.stage_enable.es_en) dump("es", regs.es_program);
    if (regs.stage_enable.gs_en) dump("gs", regs.gs_program);
    dump("vs", regs.vs_program);
    dump("ps", regs.ps_program);
}

} // namespace

// ---- Rasterizer ---------------------------------------------------------------------------------

struct Rasterizer::Impl {
    AmdGpu::Liverpool* liverpool;
    VideoCore::PageManager page_manager;
    // Guest memory the title mapped for the GPU (MapMemory/UnmapMemory).
    std::mutex mapped_mutex;
    std::map<VAddr, VAddr> mapped;  // start -> end
    // Ranges textures were filled from, watched for CPU writes (start -> size).
    std::mutex watch_mutex;
    std::map<VAddr, u64> watched;
    // Whether [a, b) overlaps a range this rasterizer protects (texture sources, memory an image is ahead of).
    bool anyWatchIn(VAddr a, VAddr b) {
        {
            std::scoped_lock l{owned_mutex};
            auto it = owned.lower_bound({a > (1ull << 30) ? a - (1ull << 30) : 0, 0});
            for (; it != owned.end() && it->first.first < b; ++it)
                if (it->first.first + it->first.second > a) return true;
        }
        std::scoped_lock l{watch_mutex};
        auto it = watched.lower_bound(a > (1ull << 30) ? a - (1ull << 30) : 0);
        for (; it != watched.end() && it->first < b; ++it)
            if (it->first + it->second > a) return true;
        return false;
    }
    // Ranges let go of lately: a second thread faulting on the same page finds the watch gone
    // already, and its access must still count as handled.
    std::array<std::pair<VAddr, u64>, 64> released{};
    u32 released_next = 0;
    bool recentlyReleased(VAddr a, u64 n) {
        for (const auto& [s, z] : released)
            if (z && s < a + n && s + z > a) return true;
        return false;
    }

    Impl(Rasterizer* self, AmdGpu::Liverpool* lp) : liverpool{lp}, page_manager{self} {}

    bool isMapped(VAddr addr, u64 size) {
        if (size == 0 || addr > ~u64(0) - size) return false;
        std::scoped_lock l{mapped_mutex};
        auto it = mapped.upper_bound(addr);
        if (it == mapped.begin()) return false;
        --it;
        return addr >= it->first && addr + size <= it->second;
    }

    void watch(VAddr a, u64 n) {
        if (!isMapped(a, n)) return;
        {
            std::scoped_lock l{watch_mutex};
            auto [it, inserted] = watched.try_emplace(a, n);
            if (!inserted) {
                if (it->second == n) return;  // already watched
                page_manager.UpdatePageWatchers<false>(a, it->second);
                it->second = n;
            }
        }
        page_manager.UpdatePageWatchers<true>(a, n);
    }

    // CPU wrote [a, a + n): textures read from there are refilled, their watches dropped (the
    // pages are written freely until a texture is filled from them again).
    bool invalidate(VAddr a, u64 n) {
        std::vector<std::pair<VAddr, u64>> hit;
        {
            std::scoped_lock l{watch_mutex};
            // (a texture starts at most 1 GiB below what it spans)
            auto it = watched.lower_bound(a > (1ull << 30) ? a - (1ull << 30) : 0);
            while (it != watched.end() && it->first < a + n) {
                if (it->first + it->second > a) {
                    hit.push_back(*it);
                    released[released_next++ % released.size()] = *it;
                    it = watched.erase(it);
                } else {
                    ++it;
                }
            }
        }
        for (auto [s, z] : hit) {
            page_manager.UpdatePageWatchers<false>(s, z);
            engine().queueInvalidate(s, z);
        }
        if (!hit.empty()) return true;
        std::scoped_lock l{watch_mutex};
        return recentlyReleased(a, n);
    }

    // ---- Memory an image on the GPU is ahead of --------------------------------------------------
    // Ranges whose newest bytes live in a GPU image (render target, depth buffer, storage image):
    // the pages are inaccessible to the CPU (a write watcher plus a read watcher) until the renderer
    // has written the image back (re-tiled it into the guest memory). The first access faults here.
    // Keyed by (start, size) with a count: two images may share a range.
    std::mutex owned_mutex;
    std::map<std::pair<VAddr, u64>, u32> owned;
    // When each owned range was first found ahead of memory after a write back (engine lock): past kAheadLimit
    // the owner is dropped instead of retrying the fault for ever.
    std::map<std::pair<VAddr, u64>, std::chrono::steady_clock::time_point> aheadSince;
    static constexpr std::chrono::milliseconds kAheadLimit{200};
    bool ownedWatchEnabled = std::getenv("VPK_NO_OWNED_WATCH") == nullptr;

    // Owned ranges let go of lately (resolveOwned, setOwned off): two threads that fault on the same
    // protected page both end up here, and the second finds the range gone. Its access is handled
    // (the first one unprotected the page): retried, not escalated to a crash. Kept for a short time
    // only, so an access that really faults for another reason cannot be retried for ever.
    struct ReleasedOwned {
        VAddr start = 0;
        u64 size = 0;
        std::chrono::steady_clock::time_point at{};
    };
    std::array<ReleasedOwned, 32> releasedOwned{};
    u32 releasedOwnedNext = 0;
    void noteReleasedOwned(VAddr a, u64 n) {  // owned_mutex held
        releasedOwned[releasedOwnedNext++ % releasedOwned.size()] = {a, n, std::chrono::steady_clock::now()};
    }
    bool recentlyReleasedOwned(VAddr addr) {
        std::scoped_lock l{owned_mutex};
        const auto now = std::chrono::steady_clock::now();
        for (const auto& r : releasedOwned)
            if (r.size && addr >= r.start && addr < r.start + r.size && now - r.at < std::chrono::milliseconds(200)) return true;
        return false;
    }

    void setOwned(VAddr a, u64 n, bool on) {
        if (!ownedWatchEnabled || n == 0) return;
        if (on && !isMapped(a, n)) return;
        std::scoped_lock l{owned_mutex};
        if (on) {
            if (owned[{a, n}]++ != 0) return;
            // (re-protected: a fault here is a fresh one, not the late arrival of the access that released it)
            for (auto& r : releasedOwned)
                if (r.size && r.start < a + n && r.start + r.size > a) r.size = 0;
            page_manager.UpdatePageWatchers<true>(a, n);
            page_manager.UpdateReadWatchers<true>(a, n);
        } else {
            auto it = owned.find({a, n});
            if (it == owned.end()) return;
            if (--it->second != 0) return;
            owned.erase(it);
            noteReleasedOwned(a, n);
            page_manager.UpdateReadWatchers<false>(a, n);
            page_manager.UpdatePageWatchers<false>(a, n);
        }
    }

    // The owned ranges that contain `addr`.
    std::vector<std::pair<VAddr, u64>> ownedAt(VAddr addr) {
        std::vector<std::pair<VAddr, u64>> hit;
        std::scoped_lock l{owned_mutex};
        auto it = owned.lower_bound({addr > (1ull << 30) ? addr - (1ull << 30) : 0, 0});
        for (; it != owned.end() && it->first.first <= addr; ++it)
            if (addr < it->first.first + it->first.second) hit.push_back(it->first);
        return hit;
    }

    // Takes every watch off the owned ranges that overlap [a, a + n) (they are being unmapped).
    void dropOwned(VAddr a, u64 n) {
        std::scoped_lock l{owned_mutex};
        for (auto it = owned.begin(); it != owned.end();) {
            if (it->first.first < a + n && it->first.first + it->first.second > a) {
                for (u32 k = 0; k < it->second; ++k) {
                    page_manager.UpdateReadWatchers<false>(it->first.first, it->first.second);
                    page_manager.UpdatePageWatchers<false>(it->first.first, it->first.second);
                }
                noteReleasedOwned(it->first.first, it->first.second);
                it = owned.erase(it);
            } else {
                ++it;
            }
        }
    }

    // The CPU touched memory an image is ahead of (`write`: it is about to write it). The renderer
    // writes the images over it back, the GPU finishes that, and the pages are released; a CPU write
    // then changes bytes the image does not have, so the images are told (they are filled again).
    // True if the access belonged to an owned range (the access is retried).
    bool resolveOwned(VAddr addr, bool write);
};

Rasterizer::Rasterizer(AmdGpu::Liverpool* liverpool) : impl{std::make_unique<Impl>(this, liverpool)} {
    liverpool->BindRasterizer(this);
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    // Page watches only where the GPU buffers alias a mirror of guest memory (vpkengine_mirror.h):
    // a watched (read-only) guest page cannot be aliased by a no-copy Metal buffer (log 17:49: guest
    // buffer of 0x706c000000 refused, 40 resources missing a frame, black picture), but the mirror
    // is another mapping of the same pages that stays writable. The renderer asks for watches only
    // over mirrored regions; elsewhere it finds CPU writes by content.
    Impl* const raw = impl.get();
    e.watchWrites = [raw](u64 a, u64 n) { raw->watch(a, n); };
    e.watchOwned = [raw](u64 a, u64 n, bool on) { raw->setOwned(a, n, on); };
    gWatchProbeContext.store(raw, std::memory_order_release);
    gWatchProbe.store([](void* ctx, u64 a, u64 b) { return static_cast<Impl*>(ctx)->anyWatchIn(a, b); },
                      std::memory_order_release);
    e.start();
}

Rasterizer::~Rasterizer() {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.watchWrites = nullptr;
    e.watchOwned = nullptr;
    if (e.renderer) e.renderer->flushReports();
    flushLeftOut();
    gWatchProbe.store(nullptr, std::memory_order_release);
    gWatchProbeContext.store(nullptr, std::memory_order_release);
}

void Rasterizer::Draw(bool is_indexed, u32 index_offset) {
    Engine::Timer timer{engine().adapterNs};
    engine().adapterCalls.fetch_add(1, std::memory_order_relaxed);
    const auto& regs = impl->liverpool->regs;
    using Mode = AmdGpu::ColorControl::OperationMode;
    switch (regs.color_control.mode) {
    // No-ops by design: the host keeps no CMASK/FMASK compression (a fast clear is a real clear, an FMask
    // read is the identity map), so there is nothing to eliminate or decompress.
    case Mode::EliminateFastClear:
    case Mode::FmaskDecompress: return;
    case Mode::Resolve: {
        if (!regs.color_buffers[0] || !regs.color_buffers[1]) return;
        Engine& e = engine();
        std::scoped_lock g{e.lock};
        if (!e.start()) return;
        e.applyPending();
        e.renderer->resolve(colorTarget(regs, 0), colorTarget(regs, 1));
        e.noteWork();
        return;
    }
    default: break;
    }
    if (regs.primitive_type == AmdGpu::PrimitiveType::None) return;
    auditContextRegs(regs);
    // Pipeline kinds: VS only, ES+GS+copy VS (run by VPKEngine as compute + a normal draw). LS/HS
    // (tessellation), an on-chip GS and stream out are not supported: those draws are left out.
    const bool geometry = regs.stage_enable.es_en || regs.stage_enable.gs_en;
    if (regs.stage_enable.ls_en || regs.stage_enable.hs_en) {
        describeGeometryDraw(regs);
        return leftOut("tessellation pipeline (LS/HS stages)");
    }
    if (geometry) {
        describeGeometryDraw(regs);  // (logs the first few distinct ones)
        if (!regs.stage_enable.es_en || !regs.stage_enable.gs_en)
            return leftOut("ES/GS stage enable combination (one of the two missing)");
        if (regs.vgt_gs_mode.onchip) return leftOut("on-chip geometry shader");
        if (regs.vgt_strmout_config.raw) return leftOut("geometry shader with stream out");
        if (!regs.es_program.Address<VAddr>() || !regs.gs_program.Address<VAddr>())
            return leftOut("geometry pipeline without an ES or GS program");
    }

    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.start()) return;
    e.applyPending();
    vpps4::DrawState d;

    // Targets.
    if (regs.color_control.mode != Mode::Disable)
        for (unsigned i = 0; i < 8; ++i) {
            const auto& cb = regs.color_buffers[i];
            if (!cb) continue;
            vpps4::ColorTarget& c = d.color[i];
            c = colorTarget(regs, i);
            // The size the title set the target up with (SetRenderTarget's extent), not the tile-aligned
            // pitch and height: sizes, viewports and later reads of the target agree with the title's.
            if (const auto& ext = impl->liverpool->last_cb_extent[i]; ext.Valid() && ext.width <= c.width && ext.height <= c.height) {
                c.width = ext.width;
                c.height = ext.height;
            }
            c.writeMask = uint8_t(regs.color_target_mask.GetMask(i) & regs.color_shader_mask.GetMask(i));
            c.forceDstAlpha1 = cb.attrib.force_dst_alpha_1;
            c.blendClamp = cb.info.blend_clamp;
            c.blendBypass = cb.info.blend_bypass;
            const auto& b = regs.blend_control[i];
            vpps4::Blend& bl = d.blend[i];
            bl.enable = b.enable;
            bl.separateAlpha = b.separate_alpha_blend;
            bl.colorSrc = uint8_t(b.color_src_factor);
            bl.colorDst = uint8_t(b.color_dst_factor);
            bl.colorFunc = uint8_t(b.color_func);
            bl.alphaSrc = uint8_t(b.alpha_src_factor);
            bl.alphaDst = uint8_t(b.alpha_dst_factor);
            bl.alphaFunc = uint8_t(b.alpha_func);
            bl.disableRop3 = b.disable_rop3;
        }
    d.rop3 = uint8_t(regs.color_control.rop3);
    d.degamma = regs.color_control.degamma_enable;
    // DB_ALPHA_TO_MASK.ALPHA_TO_MASK_ENABLE (0xA2DC), unless DB_SHADER_CONTROL turns it off.
    d.alphaToMask = (regs.reg_array[0xA2DC] & 1u) != 0 && !regs.depth_shader_control.alpha_to_mask_disable;
    d.psKill = regs.depth_shader_control.kill_enable;
    d.psExportsZ = regs.depth_shader_control.z_export_enable;
    d.psExportsStencil = regs.depth_shader_control.stencil_test_val_export_enable ||
                         regs.depth_shader_control.stencil_op_val_export_enable;
    d.psExportsMask = regs.depth_shader_control.mask_export_enable;
    d.blendColor = regs.blend_constants;
    const auto& db = regs.depth_buffer;
    if (db.DepthValid() || db.StencilValid()) {
        d.depth.zAddress = db.DepthAddress();
        d.depth.stencilAddress = db.StencilAddress();
        d.depth.width = db.Pitch();
        d.depth.height = db.Height();
        d.depth.zFormat = db.DepthValid() ? uint8_t(db.z_info.format) : 0;
        d.depth.stencilFormat = db.StencilValid() ? uint8_t(db.stencil_info.format) : 0;
        d.depth.tileMode = uint8_t(db.z_info.tile_mode_index);
        d.depth.sliceStart = uint16_t(regs.depth_view.slice_start);
        d.depth.sliceCount = uint16_t(regs.depth_view.NumSlices());
        d.depth.samples = uint8_t(db.NumSamples());
        d.depth.depthClear = regs.depth_render_control.depth_clear_enable;
        d.depth.stencilClear = regs.depth_render_control.stencil_clear_enable;
        d.depth.clearDepth = regs.depth_clear;
        d.depth.clearStencil = uint8_t(regs.stencil_clear);
        if (const auto& ext = impl->liverpool->last_db_extent; ext.Valid() && ext.width <= d.depth.width && ext.height <= d.depth.height) {
            d.depth.width = ext.width;
            d.depth.height = ext.height;
        }
        // Tested against the read base, written at the write base.
        d.depth.zWriteAddress = db.DepthWriteValid() ? db.DepthWriteAddress() : 0;
        d.depth.stencilWriteAddress = db.StencilWriteValid() ? db.StencilWriteAddress() : 0;
        d.depth.zReadOnly = regs.depth_view.z_read_only;
        d.depth.stencilReadOnly = regs.depth_view.stencil_read_only;
        const auto& ov = regs.depth_render_override;
        d.depth.forceZDirty = ov.force_z_dirty;
        d.depth.forceZValid = ov.force_z_valid;
        d.depth.forceStencilDirty = ov.force_stencil_dirty;
        d.depth.forceStencilValid = ov.force_stencil_valid;
        d.depth.boundsMin = regs.depth_bounds_min;
        d.depth.boundsMax = regs.depth_bounds_max;
        d.depth.depthCopy = regs.depth_render_control.depth_copy;
        d.depth.copySample = uint8_t(regs.depth_render_control.copy_sample);
    }
    const auto& dc = regs.depth_control;
    d.depthStencil.depthTest = dc.depth_enable;
    d.depthStencil.depthWrite = dc.depth_enable && dc.depth_write_enable;
    d.depthStencil.depthFunc = uint8_t(dc.depth_func);
    d.depthStencil.stencilTest = dc.stencil_enable;
    d.depthStencil.backfaceEnable = dc.backface_enable;
    d.depthStencil.depthBounds = dc.depth_bounds_enable;
    d.depthStencil.colorWritesOnDepthFail = dc.enable_color_writes_on_depth_fail;
    d.depthStencil.noColorWritesOnDepthPass = dc.disable_color_writes_on_depth_pass;
    const auto& sc = regs.stencil_control;
    d.depthStencil.front = {uint8_t(dc.stencil_ref_func), uint8_t(sc.stencil_fail_front), uint8_t(sc.stencil_zpass_front),
                            uint8_t(sc.stencil_zfail_front), regs.stencil_ref_front.stencil_test_val,
                            regs.stencil_ref_front.stencil_mask, regs.stencil_ref_front.stencil_write_mask,
                            regs.stencil_ref_front.stencil_op_val};
    d.depthStencil.back = {uint8_t(dc.stencil_bf_func), uint8_t(sc.stencil_fail_back), uint8_t(sc.stencil_zpass_back),
                           uint8_t(sc.stencil_zfail_back), regs.stencil_ref_back.stencil_test_val,
                           regs.stencil_ref_back.stencil_mask, regs.stencil_ref_back.stencil_write_mask,
                           regs.stencil_ref_back.stencil_op_val};

    // Rasterizer state.
    const auto& vp = regs.viewports[0];
    // PA_CL_VTE_CNTL: a transform that is switched off is the identity (scale 1, offset 0). With the x / y
    // scale off the vertices are already screen coordinates: the renderer then maps the whole target
    // (vpps4::Viewport::xScreen / yScreen), not a 2x2 viewport.
    const auto& vte = regs.viewport_control;
    d.viewport = {vte.xscale_enable ? vp.xscale : 1.0f, vte.xoffset_enable ? vp.xoffset : 0.0f,
                  vte.yscale_enable ? vp.yscale : 1.0f, vte.yoffset_enable ? vp.yoffset : 0.0f,
                  vte.zscale_enable ? vp.zscale : 1.0f, vte.zoffset_enable ? vp.zoffset : 0.0f};
    d.viewport.xScreen = !vte.xscale_enable;
    d.viewport.yScreen = !vte.yscale_enable;
    // Scissors: screen, window and generic (the last two shifted by the window offset), and the
    // viewport scissor when enabled; combined by the renderer.
    {
        auto plain = [](const AmdGpu::Scissor& q) {
            return vpps4::Scissor{q.top_left_x, q.top_left_y, q.bottom_right_x, q.bottom_right_y};
        };
        auto boxed = [](const AmdGpu::ViewportScissor& q) {
            return vpps4::Scissor{int32_t(q.top_left_x), int32_t(q.top_left_y), int32_t(q.bottom_right_x), int32_t(q.bottom_right_y)};
        };
        vpps4::ScissorRegs& sr = d.scissorRegs;
        sr.present = true;
        sr.screen = plain(regs.screen_scissor);
        sr.window = boxed(regs.window_scissor);
        sr.generic = boxed(regs.generic_scissor);
        sr.viewportScissor = boxed(regs.viewport_scissors[0]);
        sr.windowOffsetX = regs.window_offset.window_x_offset;
        sr.windowOffsetY = regs.window_offset.window_y_offset;
        sr.windowOffsetDisable = regs.window_scissor.window_offset_disable;
        sr.genericOffsetDisable = regs.generic_scissor.window_offset_disable;
        sr.viewportScissorEnable = regs.mode_control.vport_scissor_enable;
    }
    vpps4::Raster& ra = d.raster;
    ra.cullFront = regs.polygon_control.cull_front;
    ra.cullBack = regs.polygon_control.cull_back;
    ra.frontFaceClockwise = regs.polygon_control.front_face == AmdGpu::FrontFace::Clockwise;
    // PA_SU_POLY_OFFSET_*: poly_offset.depth_bias is the clamp register (its first word, db_fmt_cntl, is read below).
    ra.offsetFront = regs.polygon_control.enable_polygon_offset_front;
    ra.offsetBack = regs.polygon_control.enable_polygon_offset_back;
    ra.offsetPara = regs.polygon_control.enable_polygon_offset_para;
    ra.offsetClamp = regs.poly_offset.depth_bias;
    // DB_FMT_CNTL: NEG_NUM_DB_BITS (signed byte, minus the depth bits) and DB_IS_FLOAT_FMT. A zero register
    // (never written) leaves the unit to the depth target's format.
    if (const u32 fmt = regs.poly_offset.db_fmt_cntl) {
        const int bits = -int(int8_t(fmt & 0xFF));
        ra.dbFmtValid = bits > 0 && bits <= 32;
        ra.dbBits = uint8_t(ra.dbFmtValid ? bits : 24);
        ra.dbIsFloat = (fmt >> 8) & 1;
    }
    ra.frontScale = regs.poly_offset.front_scale;
    ra.frontOffset = regs.poly_offset.front_offset;
    ra.backScale = regs.poly_offset.back_scale;
    ra.backOffset = regs.poly_offset.back_offset;
    // PA_CL_CLIP_CNTL / PA_CL_VS_OUT_CNTL.
    ra.clipDisable = regs.IsClipDisabled();
    ra.zclipNearDisable = regs.clipper_control.zclip_near_disable;
    ra.zclipFarDisable = regs.clipper_control.zclip_far_disable;
    ra.clipSpaceZeroToW = regs.clipper_control.clip_space == AmdGpu::ClipSpace::ZeroToW;
    ra.userClipPlanes = uint8_t(regs.clipper_control.user_clip_plane_enable);
    ra.vsOutputsViewportIndex = regs.vs_output_control.use_vtx_viewport_idx;
    ra.vsOutputsClipDistances = regs.vs_output_control.clip_distance_enable != 0;
    ra.polygonModeEnable = regs.polygon_control.enable_polygon_mode != 0;
    ra.polygonModeFront = uint8_t(regs.polygon_control.polygon_mode_front);
    ra.polygonModeBack = uint8_t(regs.polygon_control.polygon_mode_back);
    ra.provokingLast = regs.polygon_control.provoking_vtx_last == AmdGpu::ProvokingVtxLast::Last;
    ra.lineWidth = regs.line_control.Width();
    // VGT_MULTI_PRIM_IB_RESET_EN / _INDX.
    ra.primitiveRestart = (regs.enable_primitive_restart & 1) != 0;
    ra.restartIndex = regs.primitive_restart_index;
    d.indexSwap = uint8_t(regs.index_buffer_type.swap_mode);
    d.primitive = vpps4::PrimitiveType(uint8_t(regs.primitive_type));

    // Geometry. (The fetch subroutine adds its own vertex offset SGPR: only VGT_INDX_OFFSET here.)
    d.count = regs.num_indices;
    d.instances = regs.num_instances.NumInstances();
    const bool index32 = regs.index_buffer_type.index_type == AmdGpu::IndexType::Index32;
    if (is_indexed) {
        d.indexAddress = regs.index_base_address.Address<VAddr>() + u64(index_offset) * (index32 ? 4 : 2);
        d.index32 = index32;
    }
    d.firstVertex = regs.index_offset;

    // Stages.
    // The fetch subroutine a vertex-fetching stage (VS, or the ES of a geometry pipeline) calls.
    auto attachFetch = [&e](vpps4::Stage& st) {
        if (const u64 fa = e.fetchAddresses.address(st.code, st.userData, st.userSgprs)) {
            Engine::FetchBody& body = e.fetchBodies[(fa >> 2) % e.fetchBodies.size()];
            const auto* p = reinterpret_cast<const uint32_t*>(fa);
            const u64 generation = spanCache().mapGen.load(std::memory_order_acquire);
            if (body.address == fa && body.generation == generation && body.words &&
                std::memcmp(p, body.code.data(), 4ull * body.words) == 0) {
                st.fetch = std::span<const uint32_t>(p, body.words);
            } else {
                const u64 bytes = readable(fa, 2048);
                const size_t n = bytes >= 4 ? vpps4::fetchLength(std::span<const uint32_t>(p, bytes / 4)) : 0;
                if (n) {
                    st.fetch = std::span<const uint32_t>(p, n);
                    if (n <= body.code.size()) {
                        body.address = fa;
                        body.generation = generation;  // (read before readable(): a later clear() leaves it stale)
                        body.words = u32(n);
                        std::memcpy(body.code.data(), p, 4 * n);
                    }
                }
            }
        }
    };
    fillStage(d.vs, regs.vs_program);
    d.vs.vgprCompCnt = uint8_t(regs.vs_program.settings.vgpr_comp_cnt);
    d.vs.instanceStepRate = {regs.vgt_instance_step_rate_0, regs.vgt_instance_step_rate_1};
    std::memcpy(&d.vs.vsOutCntl, &regs.vs_output_control, sizeof(u32));  // PA_CL_VS_OUT_CNTL: pos1-pos3
    if (geometry) {
        // The program in the VS registers is the GS's copy shader (it has no fetch subroutine).
        fillStage(d.es, regs.es_program);
        d.es.vgprCompCnt = uint8_t(regs.es_program.settings.vgpr_comp_cnt);
        d.es.instanceStepRate = {regs.vgt_instance_step_rate_0, regs.vgt_instance_step_rate_1};
        attachFetch(d.es);
        fillStage(d.gs, regs.gs_program);
        d.geom.enabled = true;
        d.geom.esgsItemDwords = regs.vgt_esgs_ring_itemsize;
        d.geom.gsvsVertDwords = regs.vgt_gs_vert_itemsize[0];
        d.geom.maxVertOut = regs.vgt_gs_max_vert_out;
        d.geom.outPrim = u32(regs.vgt_gs_out_prim_type.GetPrimitiveType(0));
        d.geom.gsInstances = regs.vgt_gs_instance_cnt.IsEnabled() ? u32(regs.vgt_gs_instance_cnt.count) : 1u;
    } else {
        attachFetch(d.vs);
    }
    if (regs.ps_program.Address<VAddr>() != 0) {
        fillStage(d.ps, regs.ps_program);
        u32 addr = 0;
        std::memcpy(&addr, &regs.ps_input_addr, sizeof(addr));
        d.ps.psInputAddr = addr & 0xffff;
        for (unsigned k = 0; k < 8; ++k) d.ps.exportFormat[k] = uint8_t(regs.color_export_format.GetFormat(k));
        d.ps.psNumInterp = uint8_t(regs.num_interp);
        for (unsigned k = 0; k < 32; ++k) std::memcpy(&d.ps.psInputCntl[k], &regs.ps_inputs[k], sizeof(u32));
    }
    if (pendingIndirect != 0) {
        d.indirectAddress = pendingIndirect;
        d.indirectCountAddress = pendingCount;
        d.drawIndex = pendingIndex;
        if (is_indexed) d.count = std::max<u32>(regs.max_index_size, 1);
        else d.count = 1;
    }
    e.renderer->draw(d);
    e.noteWork();
}

void Rasterizer::DrawIndirect(bool is_indexed, VAddr arg_address, u32 offset, u32 size, u32 max_count,
                              VAddr count_address) {
    // Every draw reads its arguments on the GPU; with a count buffer the GPU also decides which of
    // the max_count draws are live (the converter zeroes the rest): nothing is read on the CPU.
    constexpr u32 kMaxMultiDraw = 1024;
    u32 count = std::max<u32>(max_count, 1);
    if (count > kMaxMultiDraw) {
        Census::Note("draw-skip", "multi-draw indirect beyond 1024 draws truncated", fmt::format("max_count={}", max_count));
        count = kMaxMultiDraw;
    }
    const u32 stride = size != 0 ? size : (is_indexed ? 20 : 16);
    for (u32 k = 0; k < count; ++k) {
        pendingIndirect = arg_address + offset + u64(k) * stride;
        pendingCount = count_address;
        pendingIndex = k;
        Draw(is_indexed, 0);
    }
    pendingIndirect = 0;
    pendingCount = 0;
    pendingIndex = 0;
}

void Rasterizer::DispatchDirect() {
    Dispatch(0);
}

void Rasterizer::DispatchIndirect(VAddr address, u32 offset, u32) {
    Dispatch(address + offset);
}

void Rasterizer::Dispatch(VAddr indirect) {
    Engine::Timer timer{engine().adapterNs};
    engine().adapterCalls.fetch_add(1, std::memory_order_relaxed);
    const auto& cs = impl->liverpool->GetCsRegs();
    if (cs.address == 0) return;
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.start()) return;
    e.applyPending();
    vpps4::DispatchState d;
    const auto params = AmdGpu::GetParams(cs);
    d.cs.code = params.code;
    d.cs.address = reinterpret_cast<uint64_t>(params.code.data());
    std::copy_n(cs.user_data.begin(), 16, d.cs.userData.begin());
    u64 settings = 0;
    std::memcpy(&settings, &cs.settings, sizeof(settings));
    // COMPUTE_PGM_RSRC1 is the low word, RSRC2 the high one.
    const u32 rsrc2 = u32(settings >> 32);
    d.cs.userSgprs = uint8_t((rsrc2 >> 1) & 0x1f);
    for (unsigned k = 0; k < 3; ++k) d.cs.tgidEnable[k] = (rsrc2 >> (7 + k)) & 1;
    d.cs.tgSizeEnable = (rsrc2 >> 10) & 1;
    d.cs.tidigCompCnt = uint8_t((rsrc2 >> 11) & 3);
    d.cs.ldsBytes = cs.SharedMemSize();
    d.cs.workgroupSize = {cs.num_thread_x.full, cs.num_thread_y.full, cs.num_thread_z.full};
    d.groups = {cs.dim_x, cs.dim_y, cs.dim_z};
    d.indirectAddress = indirect;
    e.renderer->dispatch(d);
    e.noteWork();
}

void Rasterizer::FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.start()) return;
    e.applyPending();
    if (is_gds) {
        // GDS is ours and CPU-visible: the GPU work that uses it is finished first (and only that).
        e.scheduler->syncGds();
        if (u32* gds = e.renderer->gds(); gds && address < 0x10000) {
            const u32 n = std::min<u32>(num_bytes, 0x10000 - u32(address)) / 4;
            std::fill_n(gds + address / 4, n, value);
        }
        return;
    }
    // DMA runs on the CPU, in order: the command processor and the title may read the result
    // right after this packet (e.g. PM4 or shader code assembled by DMA, then an IndirectBuffer),
    // which a blit queued for the end of the frame would not have written yet. Memory is unified,
    // so the GPU's earlier work is finished first and then the bytes are written in place.
    // Only when queued GPU work may touch the range (the renderer keeps the guest ranges bound
    // since the GPU was last idle): otherwise the bytes are written at once, no submit, no wait.
    e.syncForDma(address, num_bytes);
    // (a range the probe cannot vouch for, e.g. across its window, keeps the GPU blit)
    if (readable(address, num_bytes) < num_bytes) {
        e.renderer->fill(address, num_bytes, value);
        e.noteWork();
        return;
    }
    auto* p = reinterpret_cast<u8*>(address);
    u64 k = 0;
    for (; k + 4 <= num_bytes; k += 4) std::memcpy(p + k, &value, 4);
    for (; k < num_bytes; ++k) p[k] = u8(value >> (8 * (k & 3)));
    e.renderer->invalidate(address, num_bytes);  // (no page watches: tell the texture cache)
}

void Rasterizer::CopyBuffer(VAddr dst, VAddr src, u32 num_bytes, bool dst_gds, bool src_gds) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.start()) return;
    e.applyPending();
    if (dst_gds || src_gds) {
        e.scheduler->syncGds();
        u32* gds = e.renderer->gds();
        if (!gds) return;
        auto* gb = reinterpret_cast<u8*>(gds);
        if (dst_gds && src_gds) {
            if (dst < 0x10000 && src < 0x10000)
                std::memmove(gb + dst, gb + src, std::min<u64>(num_bytes, 0x10000 - std::max(dst, src)));
        } else if (dst_gds) {
            if (dst < 0x10000 && readable(src, num_bytes) >= num_bytes)
                std::memcpy(gb + dst, reinterpret_cast<const void*>(src), std::min<u64>(num_bytes, 0x10000 - dst));
        } else if (src < 0x10000 && readable(dst, num_bytes) >= num_bytes) {
            std::memcpy(reinterpret_cast<void*>(dst), gb + src, std::min<u64>(num_bytes, 0x10000 - src));
            impl->invalidate(dst, num_bytes);
        }
        return;
    }
    // On the CPU and in order, for the same reason as FillBuffer (synced only when needed).
    e.syncForDma(src, num_bytes, dst, num_bytes);
    if (readable(src, num_bytes) < num_bytes || readable(dst, num_bytes) < num_bytes) {
        e.renderer->copy(dst, src, num_bytes);
        e.noteWork();
        return;
    }
    std::memmove(reinterpret_cast<void*>(dst), reinterpret_cast<const void*>(src), num_bytes);
    e.renderer->invalidate(dst, num_bytes);
}

u32 Rasterizer::ReadDataFromGds(u32 gds_offset) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.renderer) return 0;
    u32* gds = e.renderer->gds();
    return gds && gds_offset < 0x10000 ? gds[gds_offset / 4] : 0;
}

bool Rasterizer::InvalidateMemory(VAddr addr, u64 size) {
    if (!impl->isMapped(addr, std::max<u64>(size, 1))) return false;
    const bool owned = impl->resolveOwned(addr, true);
    return impl->invalidate(addr, std::max<u64>(size, 1)) || owned;
}

// The CPU read memory that an image on the GPU is ahead of (render targets are not written back by
// themselves): the renderer re-tiles the image into the guest memory, the GPU finishes it, and the
// read is retried.
bool Rasterizer::ReadMemory(VAddr addr, u64 size) {
    if (!impl->isMapped(addr, std::max<u64>(size, 1))) return false;
    return impl->resolveOwned(addr, false);
}

bool Rasterizer::Impl::resolveOwned(VAddr addr, bool write) {
    const auto hit = ownedAt(addr);
    // (another thread resolved this page between the fault and here: the access is retried)
    if (hit.empty()) return recentlyReleasedOwned(addr);
    Engine& e = engine();
    bool stillAhead = false;
    {
        // One critical section from the write back to the release (engine lock, then owned_mutex: the
        // order setOwned takes them in): the renderer records under the engine lock, so an image cannot
        // take the range over again between the write back and the page release, which would leave an
        // image ahead of memory on pages the CPU can touch.
        std::scoped_lock g{e.lock};
        e.applyPending();
        if (e.renderer) {
            // (writes the images back and waits only for the frames that touch those ranges)
            for (auto [s, z] : hit) e.syncForDma(s, z);
        }
        std::vector<std::pair<VAddr, u64>> overdue;
        {
            std::scoped_lock l{owned_mutex};
            const auto now = std::chrono::steady_clock::now();
            for (auto [s, z] : hit) {
                auto it = owned.find({s, z});
                if (it == owned.end()) {
                    aheadSince.erase({s, z});
                    continue;
                }
                // An image that could not be written back yet (its kernel is still compiling) is still ahead
                // of the memory: the pages stay protected and the access is retried, for a while.
                if (e.renderer && e.renderer->tracker().ownerImage(s, z) != 0) {
                    const auto since = aheadSince.try_emplace({s, z}, now).first->second;
                    if (now - since < kAheadLimit) {
                        stillAhead = true;
                        continue;
                    }
                    overdue.push_back({s, z});  // never written back (layout the re-tiler refuses): give up below
                    continue;
                }
                aheadSince.erase({s, z});
                for (u32 k = 0; k < it->second; ++k) {
                    page_manager.UpdateReadWatchers<false>(s, z);
                    page_manager.UpdatePageWatchers<false>(s, z);
                }
                owned.erase(it);
                noteReleasedOwned(s, z);
                if (write) e.queueInvalidate(s, z);
            }
        }
        // (outside owned_mutex: dropping the owner hands the host its page release, which takes it)
        for (auto [s, z] : overdue) {
            aheadSince.erase({s, z});
            e.renderer->abandonOwners(s, z);
            Census::Note("owned-abandoned", fmt::format("{:#x}+{:#x}", s, z),
                         "image ahead of memory could not be written back for 200 ms: pages released, memory left as it is");
            {
                std::scoped_lock l{owned_mutex};
                if (owned.erase({s, z})) {  // (abandonOwners releases through setOwned; this covers a count left over)
                    page_manager.UpdateReadWatchers<false>(s, z);
                    page_manager.UpdatePageWatchers<false>(s, z);
                    noteReleasedOwned(s, z);
                }
            }
            if (write) e.queueInvalidate(s, z);
        }
    }
    if (stillAhead) std::this_thread::sleep_for(std::chrono::milliseconds(1));  // (outside the lock)
    return true;
}

bool Rasterizer::IsMapped(VAddr addr, u64 size) {
    return impl->isMapped(addr, size);
}

void Rasterizer::MapMemory(VAddr addr, u64 size) {
    {
        std::scoped_lock l{impl->mapped_mutex};
        VAddr start = addr, end = addr + size;
        // Merge with neighbours.
        auto it = impl->mapped.upper_bound(start);
        if (it != impl->mapped.begin()) {
            auto prev = std::prev(it);
            if (prev->second >= start) {
                start = prev->first;
                end = std::max(end, prev->second);
                it = impl->mapped.erase(prev);
            }
        }
        while (it != impl->mapped.end() && it->first <= end) {
            end = std::max(end, it->second);
            it = impl->mapped.erase(it);
        }
        impl->mapped[start] = end;
    }
    impl->page_manager.OnGpuMap(addr, size);
    spanCache().clear();
}

void Rasterizer::UnmapMemory(VAddr addr, u64 size) {
    impl->invalidate(addr, size);
    // The memory is gone whatever was watched there: the tracker forgets what it knew (stale owners
    // included) and textures made from it are refilled if the range is mapped again.
    engine().queueInvalidate(addr, size);
    impl->dropOwned(addr, size);
    impl->page_manager.OnGpuUnmap(addr, size);
    std::scoped_lock l{impl->mapped_mutex};
    const VAddr end = addr + size;
    auto it = impl->mapped.upper_bound(addr);
    if (it != impl->mapped.begin()) --it;
    std::vector<std::pair<VAddr, VAddr>> keep;
    while (it != impl->mapped.end() && it->first < end) {
        if (it->second <= addr) {
            ++it;
            continue;
        }
        if (it->first < addr) keep.push_back({it->first, addr});
        if (it->second > end) keep.push_back({end, it->second});
        it = impl->mapped.erase(it);
    }
    for (auto [s, t] : keep) impl->mapped[s] = t;
    spanCache().clear();
}

// ZPASS_DONE: the renderer counts the samples that pass and writes them when the GPU is done.
bool Rasterizer::ZPassDone(VAddr address, u32 pairs) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.start()) return false;
    e.applyPending();
    return e.renderer->zpassDone(address, pairs);
}

// The command processor reads occlusion results (SET_PREDICATION, OCCLUSION_QUERY): with `wait`
// the GPU is finished first (submit + wait, then the results are written).
bool Rasterizer::SyncGpuWrites(VAddr addr, u64 size, bool wait) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.renderer) return true;
    e.applyPending();
    bool final = true;
    if (e.renderer->occlusionPending(addr, size)) {
        if (!wait) {
            e.renderer->drainOcclusion(false);
            final = !e.renderer->occlusionPending(addr, size);
        } else {
            if (e.scheduler) e.scheduler->finish();  // (submits what is recorded and waits for the GPU)
            e.renderer->drainOcclusion(true);
        }
    }
    // The command processor reads guest memory that a label write (EOP / EOS / RELEASE_MEM) or GPU work
    // queued earlier may still change: the same wait as a DMA read (images ahead of the memory are
    // written back, only the frames that touch the range are waited for). Without `wait` the work that
    // produces it is put on the GPU and the call only reports.
    if (e.scheduler) {
        const u64 a = addr, n = std::max<u64>(size, 1);
        if (wait) {
            e.syncForDma(a, n);
        } else {
            e.scheduler->prepareWait(a, n);
            final = final && !e.renderer->labelPending(a, static_cast<u32>(std::min<u64>(n, ~0u)));
        }
    }
    return final;
}

// ACQUIRE_MEM / SURFACE_SYNC. Metal orders GPU work itself and guest memory is unified, so a flush of
// the GPU's own caches needs nothing (the memory tracker orders the images; render targets reach
// memory lazily, when the CPU or a raw access needs them). When the title invalidates the readers'
// caches over a bounded range, whatever the host cannot watch there is looked at again (shader code,
// textures without write watches): Renderer::coherencePoint.
void Rasterizer::OnCoherencePoint(VAddr base, u64 size, u32 coher_cntl) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.applyPending();
    if (e.renderer && size && AmdGpu::Pm4::CoherInvalidatesReaders(coher_cntl))
        e.renderer->coherencePoint(base, size);
}

u64 Rasterizer::Flush() {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.applyPending();
    // A Liverpool command buffer batch ended (SubmitDone, ~15 a picture): the work stays recorded
    // and joins the picture's frame, which goes to the GPU when it is presented, when the CPU needs
    // it (DMA, GDS, a label wait) or when the policy says it has waited long enough (labels).
    if (e.scheduler) e.scheduler->flush();
    return e.submits.load();
}

void Rasterizer::Finish() {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.applyPending();
    if (e.scheduler) e.scheduler->finish();
    if (e.renderer) e.renderer->drainOcclusion(true);  // ZPASS_DONE results: the GPU is idle
}

void Rasterizer::SyncGds() {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.applyPending();
    if (e.scheduler) e.scheduler->syncGds();
}

void Rasterizer::ScheduleLabelWrite(void* address, u64 value, u32 size, std::function<void()> then) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.scheduler) {  // no GPU work can exist
        if (address) VideoCore::WriteGuestLabel(address, value, size);
        if (then) then();
        return;
    }
    // Written (and the interrupt raised) once the GPU has finished the work recorded so far: on
    // Metal's completion thread, or at once if there is none outstanding.
    e.scheduler->scheduleLabel(reinterpret_cast<u64>(address), address ? size : 0, bool(then),
                               [address, value, size, then = std::move(then)] {
                                   if (address) VideoCore::WriteGuestLabel(address, value, size);
                                   if (then) then();
                               },
                               value, address != nullptr);
    e.watchCv.notify_one();  // (a label is waiting: the watchdog's deadline changed)
}

// WAIT_REG_MEM function/ref/mask as PM4CmdWaitRegMem::Test applies them (1 <, 2 <=, 3 ==, 4 !=, 5 >=, 6 >).
static bool WaitRegMemWants(u32 function, u32 ref, u32 mask, u32 value) {
    value &= mask;
    switch (function) {
    case 0: return true;
    case 1: return value < ref;
    case 2: return value <= ref;
    case 3: return value == ref;
    case 4: return value != ref;
    case 5: return value >= ref;
    case 6: return value > ref;
    default: return false;
    }
}

bool Rasterizer::PrepareLabelWait(const void* address, u32 size, u32 function, u32 ref, u32 mask) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.scheduler) return false;
    // A label write already queued behind work recorded on this in-order queue (EOP / EOS / RELEASE_MEM,
    // gfx or compute alike: one Metal queue) satisfies the wait in GPU order: the command processor
    // goes on recording, what it records runs after that work. Anything else (guest CPU, recorded
    // shader writes, unknown labels) is polled after the producer is put on the GPU.
    const auto kind = e.scheduler->prepareWait(
        reinterpret_cast<u64>(address), size,
        [=](u32 word) { return WaitRegMemWants(function, ref, mask, word); });
    return kind == vpps4::Scheduler::WaitKind::Ordered;
}

// A WAIT_REG_MEM poll found nothing: blocks on the frame that produces the value instead of spinning.
bool Rasterizer::IdleLabelWait(const void* address, u32 size) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    return e.scheduler && e.scheduler->idleWait(reinterpret_cast<u64>(address), size, 2);
}

void Rasterizer::WriteDataOrdered(void* address, const void* data, u32 size) {
    Engine& e = engine();
    {
        std::scoped_lock g{e.lock};
        // After the GPU work that reads or writes this memory, and after label writes pending for it.
        if (e.scheduler) {
            // Images ahead of this memory are written back first (and their pages released once the GPU
            // has run that): a protected page would fault in the middle of the copy.
            if (e.renderer) e.renderer->syncToMemory(reinterpret_cast<u64>(address), size);
            e.scheduler->syncCpu(reinterpret_cast<u64>(address), size, vp4gpu::SubmitReason::WriteData);
            std::memcpy(address, data, size);
            return;
        }
    }
    std::memcpy(address, data, size);
}

// ---- Presenter ----------------------------------------------------------------------------------

namespace {

constexpr u32 kSlots = 6;  // the host's (openxr_host_visionos.mm NumSlots)

// Draws an eye's picture (or the flat screen) into its area of the headset frame: sampled with
// bilinear filtering, decoded to linear light when it holds sRGB-encoded values the format does
// not say, optionally sharpened (contrast adaptive, in encoded space), red and blue swapped for
// pictures stored the other way round. The frame texture is sRGB: it encodes on write.
constexpr const char* kComposeSource = R"(
#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float2 uv; };
vertex V vp_compose_vs(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    V o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}
struct P { float sharpen; uint encoded; uint swap; uint pad; };
static float3 dec(float3 c) { return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045); }
static float3 enc(float3 c) { c = max(c, 0.0); return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, 12.92 * c, c < 0.0031308); }
static float3 shown(texture2d<float> t, sampler s, float2 uv, constant P& p) {
    float3 c = t.sample(s, uv).rgb;
    if (p.swap != 0) c = c.bgr;
    return p.encoded != 0 ? c : enc(c);
}
fragment float4 vp_compose_fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], constant P& p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 here = shown(t, s, in.uv, p);
    if (p.sharpen > 0.0) {
        float2 texel = 1.0 / float2(t.get_width(), t.get_height());
        float3 a = shown(t, s, in.uv - float2(0, texel.y), p), b = shown(t, s, in.uv + float2(0, texel.y), p);
        float3 l = shown(t, s, in.uv - float2(texel.x, 0), p), r = shown(t, s, in.uv + float2(texel.x, 0), p);
        float3 lo = min(min(min(a, b), min(l, r)), here), hi = max(max(max(a, b), max(l, r)), here);
        float3 room = sqrt(clamp(min(lo, 1.0 - hi) / max(hi, float3(1e-5)), 0.0, 1.0));
        float3 w = room * (-1.0 / mix(8.0, 5.0, clamp(p.sharpen, 0.0, 1.0)));
        here = clamp(((a + b + l + r) * w + here) / (1.0 + 4.0 * w), 0.0, 1.0);
    }
    return float4(dec(here), 1.0);
}
)";

struct Region {
    id<MTLTexture> texture;
    MTLViewport viewport;
    bool encoded = false, swap = false;
    float sharpen = 0;
};

struct PresentState {
    id<MTLRenderPipelineState> pipeline{nil};
    bool pipelineFailed = false;
    std::mutex done_mutex;
    std::condition_variable done_cv;
    std::array<bool, kSlots> done{};
    Core::Vr::Fov last_fov{};
    u32 last_eye_width = 0, last_eye_height = 0;
    float sharpen = 0;
    u64 frames = 0;
    bool started = false;

    PresentState() {
        if (const char* v = std::getenv("SHADPS4_VR_SHARPEN")) sharpen = std::clamp(float(std::atof(v)), 0.0f, 1.0f);
    }
    // Under the engine lock.
    bool ensure(Engine& e) {
        if (!e.start()) return false;
        if (!started) {
            if (!VpkengineXr::Available()) return false;
            VpkengineXr::Start(e.backend->nativeDevice());
            started = true;
        }
        return buildPipeline((__bridge id<MTLDevice>)e.backend->nativeDevice());
    }

    // The compositing pipeline (Metal source compiled at run time: ~100+ ms the first time). Built at start
    // by prewarm() on a thread of its own; ensure() waits for it if it is still running.
    std::mutex build_mutex;
    bool buildPipeline(id<MTLDevice> dev) {
        std::scoped_lock built{build_mutex};
        if (pipeline || pipelineFailed) return pipeline != nil;
        NSError* error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kComposeSource) options:nil error:&error];
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vp_compose_vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"vp_compose_fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
        if (lib) pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) {
            pipelineFailed = true;
            LOG_CRITICAL(Render_Vulkan, "VPKENGINE_PRESENT the compositing shader failed: {}",
                         error ? error.localizedDescription.UTF8String : "?");
        }
        return pipeline != nil;
    }

    // A 2D view of layer 0 of `t` (eye targets may be arrays), or `t` itself.
    static id<MTLTexture> plain(id<MTLTexture> t) {
        if (!t || t.textureType == MTLTextureType2D) return t;
        if (t.textureType == MTLTextureType2DArray || t.textureType == MTLTextureTypeCube)
            return [t newTextureViewWithPixelFormat:t.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0, 1) slices:NSMakeRange(0, 1)];
        return nil;
    }

    static bool isSrgb(MTLPixelFormat f) {
        switch (f) {
        case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatBC1_RGBA_sRGB:
        case MTLPixelFormatBC2_RGBA_sRGB:
        case MTLPixelFormatBC3_RGBA_sRGB:
        case MTLPixelFormatBC7_RGBAUnorm_sRGB: return true;
        default: return false;
        }
    }

    // The texture VPKEngine has for a T#, after recording whatever fills it.
    static id<MTLTexture> textureOf(Engine& e, const vpps4::ImageDesc& d) {
        const vp4gpu::TextureId tid = e.renderer->textureFor(d);
        if (!tid) return nil;
        return nativeTexture(e, tid);
    }

    // The Metal texture of `tid` (with the submit thread, if there is one, kept out of the backend meanwhile).
    static id<MTLTexture> nativeTexture(Engine& e, vp4gpu::TextureId tid) {
        void* native = nullptr;
        e.device->withBackend([&] { native = e.backend->nativeTexture(tid); });
        return (__bridge id<MTLTexture>)native;
    }

    // Draws `regions` into a new headset frame of width x height; -1 if the host has none free.
    // ---- EYE_STATS: what each eye picture holds, every 2 s (a black picture shows as luma 0, 0 % lit).
    std::chrono::steady_clock::time_point stats_at{};
    std::atomic<bool> stats_busy{false};

    // Mean luminance and share of non-black pixels of `tex` (shared storage, read on the CPU, every 2nd pixel).
    static void logEyeStats(u32 eye, id<MTLTexture> tex) {
        const u32 w = u32(tex.width), h = u32(tex.height);
        const MTLPixelFormat f = tex.pixelFormat;
        u32 bpp = 0;
        switch (f) {
        case MTLPixelFormatRGBA8Unorm:
        case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGB10A2Unorm: bpp = 4; break;
        case MTLPixelFormatRGBA16Float: bpp = 8; break;
        default: break;
        }
        if (!bpp || !w || !h) {
            LOG_INFO(Render_Vulkan, "EYE_STATS eye {} {}x{} format {} not measured", eye, w, h, u32(f));
            return;
        }
        std::vector<u8> bytes(size_t(w) * h * bpp);
        [tex getBytes:bytes.data() bytesPerRow:size_t(w) * bpp fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
        double luma = 0;
        u64 lit = 0, count = 0;
        for (u32 y = 0; y < h; y += 2) {
            const u8* row = bytes.data() + size_t(y) * w * bpp;
            for (u32 x = 0; x < w; x += 2) {
                const u8* px = row + size_t(x) * bpp;
                float r, g, b;
                if (f == MTLPixelFormatRGBA16Float) {
                    const __fp16* hp = reinterpret_cast<const __fp16*>(px);
                    r = hp[0], g = hp[1], b = hp[2];
                } else if (f == MTLPixelFormatRGB10A2Unorm) {
                    u32 v;
                    std::memcpy(&v, px, 4);
                    r = float(v & 1023) / 1023.f, g = float((v >> 10) & 1023) / 1023.f, b = float((v >> 20) & 1023) / 1023.f;
                } else {
                    r = px[0] / 255.f, g = px[1] / 255.f, b = px[2] / 255.f;
                }
                luma += (r + g + b) / 3.0;
                lit += (r > 0 || g > 0 || b > 0) ? 1 : 0;
                ++count;
            }
        }
        LOG_INFO(Render_Vulkan, "EYE_STATS eye {} {}x{} format {} avg_luma {:.4f} non_zero {:.1f}%", eye, w, h, u32(f),
                 count ? luma / double(count) : 0.0, count ? 100.0 * double(lit) / double(count) : 0.0);
    }

    // Under the engine lock, after the eyes' drawing is submitted: copies both eyes into shared textures
    // behind it on the queue and measures them when the copy completes.
    void eyeStats(Engine& e, const std::array<id<MTLTexture>, 2>& eyes) {
        const auto now = std::chrono::steady_clock::now();
        if (now - stats_at < std::chrono::seconds{2}) return;
        stats_at = now;
        if (!eyes[0] && !eyes[1]) return;
        if (stats_busy.exchange(true)) return;
        id<MTLDevice> dev = (__bridge id<MTLDevice>)e.backend->nativeDevice();
        std::array<id<MTLTexture>, 2> copies{};
        for (u32 k = 0; k < 2; ++k) {
            if (!eyes[k]) continue;
            MTLTextureDescriptor* td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:eyes[k].pixelFormat
                                                                                          width:eyes[k].width
                                                                                         height:eyes[k].height
                                                                                      mipmapped:NO];
            td.storageMode = MTLStorageModeShared;
            td.usage = MTLTextureUsageShaderRead;
            copies[k] = [dev newTextureWithDescriptor:td];
        }
        const std::array<id<MTLTexture>, 2> src = eyes;
        e.device->drain();
        bool queued = false;
        e.device->withBackend([&] { queued = e.backend->encodeInterop(
            [&](void* cbp) {
                id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
                id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                blit.label = @"eye stats";
                for (u32 k = 0; k < 2; ++k) {
                    if (!src[k] || !copies[k]) continue;
                    [blit copyFromTexture:src[k]
                              sourceSlice:0
                              sourceLevel:0
                             sourceOrigin:MTLOriginMake(0, 0, 0)
                               sourceSize:MTLSizeMake(src[k].width, src[k].height, 1)
                                toTexture:copies[k]
                         destinationSlice:0
                         destinationLevel:0
                        destinationOrigin:MTLOriginMake(0, 0, 0)];
                }
                [blit endEncoding];
            },
            "vp.eyestats",
            [this, copies] {
                for (u32 k = 0; k < 2; ++k)
                    if (copies[k]) logEyeStats(k, copies[k]);
                stats_busy = false;
            }); });
        if (!queued) stats_busy = false;
    }

    int compose(Engine& e, u32 width, u32 height, std::span<const Region> regions) {
        u32 target_index = 0;
        void* target_texture = nullptr;
        if (!VpkengineXr::Begin(width, height, target_index, target_texture)) return -1;
        const u32 slot = target_index % kSlots;
        {
            std::scoped_lock l{done_mutex};
            done[slot] = false;
        }
        id<MTLTexture> out = (__bridge id<MTLTexture>)target_texture;
        id<MTLRenderPipelineState> pso = pipeline;
        std::vector<Region> list(regions.begin(), regions.end());
        // The compose command buffer goes after the frames submitted before it: with the submit thread,
        // they must have reached the backend.
        e.device->drain();
        bool queued = false;
        e.device->withBackend([&] { queued = e.backend->encodeInterop(
            [&](void* cbp) {
                id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
                MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = out;
                rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
                enc.label = @"headset frame";
                [enc setRenderPipelineState:pso];
                for (const Region& r : list) {
                    if (!r.texture) continue;
                    struct {
                        float sharpen;
                        u32 encoded, swap, pad;
                    } p{r.sharpen, r.encoded ? 1u : 0u, r.swap ? 1u : 0u, 0};
                    [enc setViewport:r.viewport];
                    [enc setFragmentTexture:r.texture atIndex:0];
                    [enc setFragmentBytes:&p length:sizeof p atIndex:0];
                    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
                }
                [enc endEncoding];
            },
            "vp.headset",
            [this, slot] {
                std::scoped_lock l{done_mutex};
                done[slot] = true;
                done_cv.notify_all();
            }); });
        if (!queued) {
            VpkengineXr::Drop(target_index);
            return -1;
        }
        return int(slot);
    }
};

PresentState& present() {
    static PresentState& p = *new PresentState;
    return p;
}

void PrewarmCompose(void* nativeDevice) {
    if (!nativeDevice) return;
    id<MTLDevice> dev = (__bridge id<MTLDevice>)nativeDevice;
    std::thread([dev] { present().buildPipeline(dev); }).detach();
}

} // namespace

namespace Present {

bool HasHeadset() {
    return VpkengineXr::Available();
}

int ComposeEyes(std::span<const AmdGpu::Image, 2> eye_textures, const Core::Vr::Fov& fov, u32& eye_width,
                u32& eye_height) {
    PresentState* impl = &present();
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!impl->ensure(e)) return -1;
    e.applyPending();
    std::array<id<MTLTexture>, 2> eyes{};
    std::array<bool, 2> encoded{};
    for (u32 k = 0; k < 2; ++k) {
        std::array<u32, 8> words{};
        std::memcpy(words.data(), &eye_textures[k], std::min(sizeof words, sizeof(AmdGpu::Image)));
        const vpps4::ImageDesc d = vpps4::decodeImage(words);
        // A T# at slice k > 0 of an array colour target (stereo eyes as the two slices of one
        // target): that slice as a 2D view. Slice 0 is the target's own address (textureOf).
        u16 slice = 0;
        const vp4gpu::TextureId arrayTarget = e.renderer->colorTargetAt(d.address)
                                                 ? vp4gpu::TextureId{}
                                                 : e.renderer->colorTargetSlice(d.address, d.width, d.height, slice);
        if (arrayTarget) {
            id<MTLTexture> t = PresentState::nativeTexture(e, arrayTarget);
            eyes[k] = t && t.textureType == MTLTextureType2DArray && slice < t.arrayLength
                          ? [t newTextureViewWithPixelFormat:t.pixelFormat
                                                 textureType:MTLTextureType2D
                                                      levels:NSMakeRange(0, 1)
                                                      slices:NSMakeRange(slice, 1)]
                          : nil;
        } else {
            eyes[k] = PresentState::plain(PresentState::textureOf(e, d));
        }
        // A picture the console reads as sRGB through a format Metal has no sRGB form of.
        encoded[k] = eyes[k] && d.numFormat == 9 && !PresentState::isSrgb(eyes[k].pixelFormat);
        if (k == 0) {
            eye_width = d.width;
            eye_height = d.height;
        }
        // Where the eye comes from: a colour target VPKEngine drew, or an image filled from guest
        // memory / written by compute (first frames and every 600).
        if (impl->frames % 600 == 0)
            LOG_INFO(Render_Vulkan, "VPKENGINE_PRESENT eye {} T# {:#x} tile {} pitch {} fmt {}/{} {}x{} colour_target={} array_slice={}", k,
                     d.address, u32(d.tilingIndex), d.pitch, u32(d.dataFormat), u32(d.numFormat), d.width, d.height,
                     bool(e.renderer->colorTargetAt(d.address)), arrayTarget ? int(slice) : -1);
        // What VPKEngine holds on the GPU over the eye's memory (targets inside a bigger or
        // neighbouring surface, shader-written images of another format): the eye's real producer.
        if (impl->frames % 600 == 0)
            LOG_INFO(Render_Vulkan, "VPKENGINE_PRESENT eye {} overlaps:{}", k,
                     e.renderer->describeAt(d.address, u64(std::max(d.pitch, d.width)) * d.height * 4));
    }
    // The eyes' drawing is submitted first: the composition runs after it on the same queue.
    e.present();
    if (!eyes[0] || !eyes[1]) {
        static std::atomic<u32> told{0};
        if (told++ < 4)
            LOG_WARNING(Render_Vulkan, "VPKENGINE_PRESENT eye pictures missing (left {}, right {}): black frame",
                        eyes[0] != nil, eyes[1] != nil);
    }
    impl->eyeStats(e, eyes);
    impl->last_fov = fov;
    impl->last_eye_width = eye_width;
    impl->last_eye_height = eye_height;
    const u32 width = eye_width * 2, height = eye_height;
    std::array<Region, 2> regions{};
    for (u32 k = 0; k < 2; ++k)
        regions[k] = {eyes[k], MTLViewport{double(k * eye_width), 0, double(eye_width), double(eye_height), 0, 1},
                      encoded[k], false, impl->sharpen};
    const int slot = impl->compose(e, width, height, regions);
    if (slot < 0) return -1;
    if (impl->frames++ % 600 == 0)
        LOG_INFO(Render_Vulkan, "VPKENGINE_PRESENT headset frame {}: eyes {}x{} ({} / {}), sharpen {:.2f}", impl->frames,
                 eye_width, eye_height, eyes[0] ? eyes[0].pixelFormat : 0, eyes[1] ? eyes[1].pixelFormat : 0,
                 impl->sharpen);
    return slot;
}

} // namespace Present

namespace {

// A flat picture as a screen 70 degrees wide straight ahead, the same in both eyes: in each eye's
// picture (from the temple's tangent to the nose's, top's to bottom's), the rectangle of those
// tangents.
std::array<MTLViewport, 2> screenViewports(const Core::Vr::Fov& fov, u32 eye_width, u32 eye_height, float aspect) {
    constexpr float half_width_tan = 0.7002f;  // tan(35 degrees)
    const float half_height_tan = half_width_tan / std::max(aspect, 0.1f);
    std::array<MTLViewport, 2> out{};
    for (u32 eye = 0; eye < 2; ++eye) {
        const float left_tan = eye == 0 ? fov.tan_out : fov.tan_in;
        const float right_tan = eye == 0 ? fov.tan_in : fov.tan_out;
        const float span_x = std::max(left_tan + right_tan, 0.01f);
        const float span_y = std::max(fov.tan_top + fov.tan_bottom, 0.01f);
        const float x0 = std::clamp((left_tan - half_width_tan) / span_x * eye_width, 0.0f, float(eye_width) - 1);
        const float x1 = std::clamp((left_tan + half_width_tan) / span_x * eye_width, x0 + 1, float(eye_width));
        const float y0 = std::clamp((fov.tan_top - half_height_tan) / span_y * eye_height, 0.0f, float(eye_height) - 1);
        const float y1 = std::clamp((fov.tan_top + half_height_tan) / span_y * eye_height, y0 + 1, float(eye_height));
        out[eye] = {double(eye * eye_width + x0), double(y0), double(x1 - x0), double(y1 - y0), 0, 1};
    }
    return out;
}

} // namespace

namespace Present {

int ComposeScreen(const Libraries::VideoOut::BufferAttributeGroup& group, VAddr cpu_address, Core::Vr::Fov& fov,
                  u32& eye_width, u32& eye_height) {
    using Libraries::VideoOut::PixelFormat;
    using Libraries::VideoOut::TilingMode;
    PresentState* impl = &present();
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!impl->ensure(e)) return -1;
    e.applyPending();
    const auto& a = group.attrib;
    vpps4::ImageDesc d;
    d.address = cpu_address;
    const bool ten = a.pixel_format == PixelFormat::A2R10G10B10 || a.pixel_format == PixelFormat::A2R10G10B10Srgb ||
                     a.pixel_format == PixelFormat::A2R10G10B10Bt2020Pq;
    d.dataFormat = ten ? 9 : 10;  // 2_10_10_10 / 8_8_8_8
    d.numFormat = a.pixel_format == PixelFormat::A8R8G8B8Srgb || a.pixel_format == PixelFormat::A8B8G8R8Srgb ? 9 : 0;
    d.width = a.width;
    d.height = a.height;
    const bool tiled = a.tiling_mode == TilingMode::Tile;
    d.pitch = tiled ? (a.width + 127) & ~127u : std::max<u32>(a.pitch_in_pixel, a.width);
    d.tilingIndex = tiled ? 10 : 8;
    d.type = 9;
    id<MTLTexture> t = PresentState::plain(PresentState::textureOf(e, d));
    e.present();
    fov = impl->last_fov;
    eye_width = impl->last_eye_width ? impl->last_eye_width : 1440;
    eye_height = impl->last_eye_height ? impl->last_eye_height : 1536;
    const auto vps = screenViewports(fov, eye_width, eye_height, a.height ? float(a.width) / float(a.height) : 16.f / 9.f);
    // Stored blue-first (A8R8G8B8, A2R10G10B10): red and blue swapped back. 10-bit "sRGB" holds
    // encoded values.
    const bool swap = a.pixel_format != PixelFormat::A8B8G8R8Srgb;
    const bool encoded = a.pixel_format == PixelFormat::A2R10G10B10Srgb;
    std::array<Region, 2> regions{Region{t, vps[0], encoded, swap, 0}, Region{t, vps[1], encoded, swap, 0}};
    return impl->compose(e, eye_width * 2, eye_height, regions);
}

int ComposeTexture(const AmdGpu::Image& texture, Core::Vr::Fov& fov, u32& eye_width, u32& eye_height) {
    PresentState* impl = &present();
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!impl->ensure(e)) return -1;
    e.applyPending();
    std::array<u32, 8> words{};
    std::memcpy(words.data(), &texture, std::min(sizeof words, sizeof(AmdGpu::Image)));
    const vpps4::ImageDesc d = vpps4::decodeImage(words);
    id<MTLTexture> t = PresentState::plain(PresentState::textureOf(e, d));
    e.present();
    fov = impl->last_fov;
    eye_width = impl->last_eye_width ? impl->last_eye_width : 1440;
    eye_height = impl->last_eye_height ? impl->last_eye_height : 1536;
    const auto vps = screenViewports(fov, eye_width, eye_height, d.height ? float(d.width) / float(d.height) : 16.f / 9.f);
    const bool encoded = t && d.numFormat == 9 && !PresentState::isSrgb(t.pixelFormat);
    std::array<Region, 2> regions{Region{t, vps[0], encoded, false, 0}, Region{t, vps[1], encoded, false, 0}};
    return impl->compose(e, eye_width * 2, eye_height, regions);
}

void Deliver(int slot, const Core::Vr::PresentedFrame& info) {
    if (slot < 0) return;
    PresentState& p = present();
    const u32 s = u32(slot) % kSlots;
    {
        std::unique_lock l{p.done_mutex};
        // (a GPU that hangs gets its command buffer failed by Metal: the handler still runs)
        p.done_cv.wait_for(l, std::chrono::seconds{2}, [&] { return p.done[s]; });
    }
    VpkengineXr::End(s, info);
}

bool Finished(int slot) {
    if (slot < 0) return true;
    PresentState& p = present();
    std::scoped_lock l{p.done_mutex};
    return p.done[u32(slot) % kSlots];
}

} // namespace Present

} // namespace VpkengineRenderer
