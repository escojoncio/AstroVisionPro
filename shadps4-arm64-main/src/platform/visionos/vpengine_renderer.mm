// VPEngine: the only renderer on visionOS (see vpengine_renderer.h).
#include "vpengine_renderer.h"

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
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <span>
#include <string>
#include <vector>

#include <fmt/ranges.h>
#include "common/logging/log.h"
#include "core/libraries/videoout/buffer.h"
#include "vpengine_xr.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/amdgpu/regs.h"
#include "video_core/amdgpu/resource.h"
#include "video_core/page_manager.h"
#include "vpgpu/core/device.h"
#include "vpgpu/metal/metal_backend.h"
#include "vpps4/fetch.h"
#include "vpps4/formats.h"
#include "vpps4/renderer.h"

namespace VpengineRenderer {
namespace {

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
    };
    std::mutex m;
    std::array<Entry, 128> entries{};
    unsigned used = 0, next = 0, last = 0;
    u64 gen = 0;  // bumped by clear(): a span looked up before it is not inserted after it
    void clear() {
        std::scoped_lock l{m};
        used = next = last = 0;
        ++gen;
    }
};
SpanCache& spanCache() {
    static SpanCache& c = *new SpanCache;
    return c;
}

bool cachedSpan(u64 address, u64 from, u64 to, u64& begin, u64& end) {
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
            return true;
        }
        for (unsigned k = 0; k < c.used; ++k)
            if (hit(c.entries[k])) {
                c.last = k;
                begin = c.entries[k].begin;
                end = c.entries[k].end;
                return true;
            }
    }
    if (!mappedSpan(address, from, to, begin, end)) return false;  // (misses are not cached)
    std::scoped_lock l{c.m};
    if (c.gen != gen0) return true;  // the map changed meanwhile: use it this once, keep it out
    const unsigned k = c.used < c.entries.size() ? c.used++ : (c.next++ % unsigned(c.entries.size()));
    c.entries[k] = {from, to, begin, end};
    c.last = k;
    return true;
}

// Bytes readable from `address` on (up to `want`), 0 if it is not mapped.
u64 readable(u64 address, u64 want) {
    const u64 from = address & ~(kWindow - 1);
    u64 begin, end;
    if (!cachedSpan(address, from, from + kWindow, begin, end)) return 0;
    return std::min<u64>(want, end - address);
}

// MSL from the shader translator, as the Metal backend takes it (msl.h argument contract).
vpgpu::metal::MslShader toMetal(const vpmsl::MslShader& s) {
    vpgpu::metal::MslShader m;
    m.source = s.source;
    m.entry = "vp_main";
    m.argumentBufferIndex = 0;
    m.threadsPerGroup = s.workgroupSize;
    m.colorOutputs = s.colorOutputs;
    for (const vpmsl::Argument& a : s.arguments)
        m.arguments.push_back({vpgpu::BindKind(uint8_t(a.kind) + 1), uint16_t(a.index), a.offset});
    return m;
}

// The engine: VPEngine's Metal backend, device and PS4 renderer, shared by the rasterizer (GPU
// thread) and the presenter. Everything that records goes under `lock`.
struct Engine {
    std::mutex lock;
    vpgpu::metal::ShaderTable shaders;
    std::unique_ptr<vpgpu::metal::MetalBackend> backend;
    std::unique_ptr<vpgpu::Device> device;
    std::unique_ptr<vpps4::Renderer> renderer;
    std::atomic<u64> submits{0};
    std::atomic<unsigned> errorLines{0};
    std::function<void(u64, u64)> uploaded;  // set by the rasterizer: watch these guest pages
    // Invalidations come from the page-fault handler: queued without the engine lock (it may be
    // held for long, or by the faulting thread itself) and applied before the next command.
    std::atomic_flag pendingLock = ATOMIC_FLAG_INIT;
    std::vector<std::pair<u64, u64>> pending;
    void queueInvalidate(u64 a, u64 n) {
        while (pendingLock.test_and_set(std::memory_order_acquire)) {}
        if (pending.size() < 65536) pending.push_back({a, n});
        pendingLock.clear(std::memory_order_release);
    }
    void applyPending() {
        while (pendingLock.test_and_set(std::memory_order_acquire)) {}
        std::vector<std::pair<u64, u64>> work;
        work.swap(pending);
        pendingLock.clear(std::memory_order_release);
        if (renderer)
            for (auto [a, n] : work) renderer->invalidate(a, n);
    }
    bool failed = false;
    u64 dmaUnsynced = 0, dmaSynced = 0;  // DMA packets done on the CPU without / after a GPU wait

    // CPU time of the GPU thread, in ns, printed every ~2 s (VPENGINE_GPU cpu:). Atomics: the
    // presenter submits too, and draw timers stop after the engine lock is released.
    using Clock = std::chrono::steady_clock;
    enum Wait : unsigned { WaitDma, WaitGds, WaitFinish, WaitKinds };
    std::atomic<u64> adapterNs{0}, adapterCalls{0}, submitNs{0}, dmaSubmits{0};
    std::array<std::atomic<u64>, WaitKinds> waitNs{}, waits{};
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
    // Waits for every submitted frame (the caller submitted first when it needs recorded work too).
    void waitGpu(Wait why) {
        const auto t0 = Clock::now();
        backend->waitIdle();
        waitNs[why].fetch_add(nsSince(t0), std::memory_order_relaxed);
        waits[why].fetch_add(1, std::memory_order_relaxed);
    }
    // CPU-side DMA over guest [a, +n) (and [b, +m)): waits only when GPU work may touch it, and
    // submits first only when the overlap is in work not submitted yet.
    void syncForDma(u64 a, u64 n, u64 b = 0, u64 m = 0) {
        const bool any = renderer->gpuMayAccess(a, n) || (m && renderer->gpuMayAccess(b, m));
        if (!any) {
            ++dmaUnsynced;
            return;
        }
        ++dmaSynced;
        if (renderer->recordedMayAccess(a, n) || (m && renderer->recordedMayAccess(b, m))) {
            ++dmaSubmits;
            submit();
            waitGpu(WaitDma);
            renderer->gpuIdle();
        } else {
            waitGpu(WaitDma);
            renderer->submittedIdle();  // (work recorded since keeps its ranges)
        }
    }
    void report() {
        const double s = std::chrono::duration<double>(Clock::now() - lastReport).count();
        if (s < 2.0 || !renderer) return;
        lastReport = Clock::now();
        const vpps4::CpuTimes t = renderer->takeCpuTimes();
        auto msps = [&](u64 ns) { return double(ns) / 1e6 / s; };
        auto take = [](std::atomic<u64>& a) { return a.exchange(0, std::memory_order_relaxed); };
        const u64 calls = take(adapterCalls), adapter = take(adapterNs), sub = take(submitNs);
        const u64 wd = take(waitNs[WaitDma]), wg = take(waitNs[WaitGds]), wf = take(waitNs[WaitFinish]);
        const u64 nd = take(waits[WaitDma]), ng = take(waits[WaitGds]), nf = take(waits[WaitFinish]);
        LOG_INFO(Render_Vulkan,
                 "VPENGINE_GPU cpu: draw_adapter {:.1f} ms/s, vpps4.draw {:.1f}, shader lookup {:.1f}, bind {:.1f}, "
                 "pipeline request {:.1f}, frame compile+submit {:.1f} (vpps4 {:.1f}; {:.0f} submits/s, {:.0f} empty/s), "
                 "dma_wait {:.1f} ({:.0f}/s, {:.0f} with submit/s), gds_wait {:.1f} ({:.0f}/s), finish_wait {:.1f} ({:.0f}/s), "
                 "draws {:.0f}/s, per-draw {:.2f} us adapter / {:.2f} us vpps4, user data reused {:.0f}/s",
                 msps(adapter), t.drawMs / s, t.shaderMs / s, t.bindMs / s, t.pipelineMs / s, msps(sub),
                 t.submitMs / s, double(t.submits) / s, double(t.emptySubmits) / s, msps(wd), double(nd) / s,
                 double(take(dmaSubmits)) / s, msps(wg), double(ng) / s, msps(wf), double(nf) / s, double(calls) / s,
                 calls ? double(adapter) / 1e3 / double(calls) : 0.0, t.calls ? t.drawMs * 1e3 / double(t.calls) : 0.0,
                 double(t.userDataReused) / s);
    }

    static constexpr u64 kEvery = 120;  // per-frame lines of the core every kEvery submits
    void log(const std::string& line) {
        const bool error = line.rfind("gpu.err", 0) == 0 || line.rfind("vpps4.shader error", 0) == 0;
        if (error) {
            if (errorLines++ < 200) LOG_WARNING(Render_Vulkan, "VPENGINE_GPU {}", line);
            return;
        }
        const u64 f = submits.load();
        if (line.rfind("gpu.", 0) == 0 && line.rfind("gpu.metal", 0) != 0 && f != 0 && f % kEvery != 1) return;
        LOG_INFO(Render_Vulkan, "VPENGINE_GPU {}", line);
    }

    bool start() {
        if (renderer || failed) return renderer != nullptr;
        // Liverpool submits ~15 command buffers per presented frame: with only 3 in flight the CPU
        // blocked on the GPU's latency every few submits. vpps4's upload rings (8) cover 6 + 1.
        vpgpu::metal::MetalOptions options;
        options.framesInFlight = 6;
        backend = std::make_unique<vpgpu::metal::MetalBackend>(shaders, [this](const std::string& l) { log(l); },
                                                               options);
        if (!backend->ok()) {
            failed = true;
            LOG_CRITICAL(Render_Vulkan, "VPENGINE_GPU no Metal device: nothing can be drawn");
            return false;
        }
        device = std::make_unique<vpgpu::Device>(*backend, 2, [this](const std::string& l) { log(l); });
        vpps4::Hooks hooks;
        hooks.region = [](uint64_t address, uint64_t size, vpps4::GuestRegion& out) {
            if (address < 0x10000) return false;
            const u64 from = address & ~(kWindow - 1);
            const u64 to = std::max(from + kWindow, (address + size + kWindow - 1) & ~(kWindow - 1));
            u64 begin, end;
            if (!cachedSpan(address, from, to, begin, end) || address + size > end) return false;
            out = {begin, end - begin, reinterpret_cast<void*>(begin)};
            return true;
        };
        hooks.shader = [this](uint64_t id, vpir::Stage, const vpmsl::MslShader& s) { shaders.add(id, toMetal(s)); };
        hooks.log = [this](const std::string& l) { log(l); };
        hooks.uploaded = [this](uint64_t a, uint64_t n) {
            if (uploaded) uploaded(a, n);
        };
        renderer = std::make_unique<vpps4::Renderer>(*device, std::move(hooks));
        renderer->setSummaryEvery(kEvery);
        // No MSAA: antialiasing is temporal (VPKTAA), 1 sample per pixel. The game's MSAA targets
        // become single-sample; its resolves become copies.
        renderer->setMaxSamples(1);
        LOG_INFO(Render_Vulkan, "VPENGINE_GPU renderer on (VPEngine draws everything in Metal; no Vulkan device)");
        return true;
    }

    // Ends the frame recorded so far (one Liverpool submit).
    void submit() {
        if (!renderer) return;
        ++submits;
        // Guest mappings can change without Map/UnmapMemory (a munmap or protection change of
        // the title's): spans are looked up again (vm_region syscalls, tens per span). Once per
        // ~8 ms rather than at each of the ~15 Liverpool submits of a frame.
        if (nsSince(lastSpanClear) > 8'000'000) {
            spanCache().clear();
            lastSpanClear = Clock::now();
        }
        if (submits % kEvery == 1)
            LOG_INFO(Render_Vulkan, "VPENGINE_GPU dma: {} packets without a GPU wait, {} after one (so far)", dmaUnsynced,
                     dmaSynced);
        {
            Timer t{submitNs};
            renderer->submit();
        }
        report();
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

// CB_COLORn as VPEngine's colour target (write mask left at its default).
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
    c.samples = uint8_t(cb.NumSamples());
    return c;
}

// Counts of draws left out before the renderer, by reason (logged the first time each).
void leftOut(const char* why) {
    static std::mutex m;
    static std::map<std::string, u64> counts;
    std::scoped_lock l{m};
    const u64 n = ++counts[why];
    if (n == 1) LOG_INFO(Render_Vulkan, "VPENGINE_GPU first draw left out: {}", why);
    else if (n == 1000 || n == 10000 || n == 100000 || n % 1000000 == 0)
        LOG_INFO(Render_Vulkan, "VPENGINE_GPU draws left out: {} x{}", why, n);
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
             "VPENGINE_GEOM stages {:#x} (ls {} hs {} es {} gs {} vs {}) gs_mode {:#x} gs_instances {:#x} out_prim {} "
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
        LOG_INFO(Render_Vulkan, "VPENGINE_GEOM {} @{:#x} user_sgprs {} words {} user_data {:08x}", name, key,
                 u32(prog.settings.num_user_regs), params.code.size(),
                 fmt::join(std::span(prog.user_data.data(), 16), " "));
        if (!dumped.insert(key).second) return;
        for (size_t at = 0; at < params.code.size(); at += 128)
            LOG_INFO(Render_Vulkan, "VPENGINE_GEOM {} @{:#x} code@{}: {:08x}", name, key, at,
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
};

Rasterizer::Rasterizer(AmdGpu::Liverpool* liverpool) : impl{std::make_unique<Impl>(this, liverpool)} {
    liverpool->BindRasterizer(this);
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    // No page watches: VPEngine finds CPU writes to texture sources by their content. A watched
    // (read-only) page cannot be aliased by a no-copy Metal buffer (log 17:49: guest buffer of
    // 0x706c000000 refused, 40 resources missing a frame, black picture) and a write to it from
    // host code (an HLE strncpy) faulted in a loop.
    e.uploaded = nullptr;
    e.start();
}

Rasterizer::~Rasterizer() {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.uploaded = nullptr;
}

void Rasterizer::Draw(bool is_indexed, u32 index_offset) {
    Engine::Timer timer{engine().adapterNs};
    engine().adapterCalls.fetch_add(1, std::memory_order_relaxed);
    const auto& regs = impl->liverpool->regs;
    using Mode = AmdGpu::ColorControl::OperationMode;
    switch (regs.color_control.mode) {
    case Mode::EliminateFastClear: return leftOut("fast clear elimination (no fast-clear metadata)");
    case Mode::FmaskDecompress: return leftOut("FMask decompression (no MSAA on the host)");
    case Mode::Resolve: {
        if (!regs.color_buffers[0] || !regs.color_buffers[1]) return;
        Engine& e = engine();
        std::scoped_lock g{e.lock};
        if (!e.start()) return;
        e.applyPending();
        e.renderer->resolve(colorTarget(regs, 0), colorTarget(regs, 1));
        return;
    }
    default: break;
    }
    if (regs.primitive_type == AmdGpu::PrimitiveType::None) return;
    if (regs.stage_enable.es_en || regs.stage_enable.ls_en || regs.stage_enable.gs_en || regs.stage_enable.hs_en)
    {
        describeGeometryDraw(regs);
        return leftOut("geometry / tessellation pipeline (ES/LS stages)");
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
            c.writeMask = uint8_t(regs.color_target_mask.GetMask(i) & regs.color_shader_mask.GetMask(i));
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
        }
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
    }
    const auto& dc = regs.depth_control;
    d.depthStencil.depthTest = dc.depth_enable;
    d.depthStencil.depthWrite = dc.depth_enable && dc.depth_write_enable;
    d.depthStencil.depthFunc = uint8_t(dc.depth_func);
    d.depthStencil.stencilTest = dc.stencil_enable;
    d.depthStencil.backfaceEnable = dc.backface_enable;
    const auto& sc = regs.stencil_control;
    d.depthStencil.front = {uint8_t(dc.stencil_ref_func), uint8_t(sc.stencil_fail_front), uint8_t(sc.stencil_zpass_front),
                            uint8_t(sc.stencil_zfail_front), regs.stencil_ref_front.stencil_test_val,
                            regs.stencil_ref_front.stencil_mask, regs.stencil_ref_front.stencil_write_mask};
    d.depthStencil.back = {uint8_t(dc.stencil_bf_func), uint8_t(sc.stencil_fail_back), uint8_t(sc.stencil_zpass_back),
                           uint8_t(sc.stencil_zfail_back), regs.stencil_ref_back.stencil_test_val,
                           regs.stencil_ref_back.stencil_mask, regs.stencil_ref_back.stencil_write_mask};

    // Rasterizer state.
    const auto& vp = regs.viewports[0];
    d.viewport = {vp.xscale, vp.xoffset, vp.yscale, vp.yoffset, vp.zscale, vp.zoffset};
    const auto& ss = regs.screen_scissor;
    d.scissor = {ss.top_left_x, ss.top_left_y, ss.bottom_right_x, ss.bottom_right_y};
    d.raster.cullFront = regs.polygon_control.cull_front;
    d.raster.cullBack = regs.polygon_control.cull_back;
    d.raster.frontFaceClockwise = regs.polygon_control.front_face == AmdGpu::FrontFace::Clockwise;
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
    fillStage(d.vs, regs.vs_program);
    d.vs.vgprCompCnt = uint8_t(regs.vs_program.settings.vgpr_comp_cnt);
    d.vs.instanceStepRate = {regs.vgt_instance_step_rate_0, regs.vgt_instance_step_rate_1};
    if (const u64 fa = vpps4::fetchAddress(d.vs.code, d.vs.userData, d.vs.userSgprs)) {
        const u64 bytes = readable(fa, 2048);
        const auto* p = reinterpret_cast<const uint32_t*>(fa);
        const size_t n = bytes >= 4 ? vpps4::fetchLength(std::span<const uint32_t>(p, bytes / 4)) : 0;
        if (n) d.vs.fetch = std::span<const uint32_t>(p, n);
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
        if (is_indexed) d.count = std::max<u32>(regs.max_index_size, 1);
        else d.count = 1;
    }
    e.renderer->draw(d);
}

void Rasterizer::DrawIndirect(bool is_indexed, VAddr arg_address, u32 offset, u32 size, u32 max_count,
                              VAddr count_address) {
    u32 count = std::max<u32>(max_count, 1);
    if (count_address != 0) {
        // The count the GPU would read, as the CPU sees it now (GPU work that writes it in this
        // frame is not seen).
        u32 n = 0;
        if (readable(count_address, 4) >= 4) std::memcpy(&n, reinterpret_cast<const void*>(count_address), 4);
        count = std::min(count, n);
        leftOut("indirect draw count read from memory by the CPU (approximation)");
    }
    const u32 stride = size != 0 ? size : (is_indexed ? 20 : 16);
    for (u32 k = 0; k < count; ++k) {
        pendingIndirect = arg_address + offset + u64(k) * stride;
        Draw(is_indexed, 0);
    }
    pendingIndirect = 0;
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
}

void Rasterizer::FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.start()) return;
    e.applyPending();
    if (is_gds) {
        // GDS is ours and CPU-visible: the GPU's earlier work is finished first.
        e.submit();
        e.waitGpu(Engine::WaitGds);
        e.renderer->gpuIdle();
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
        e.submit();
        e.waitGpu(Engine::WaitGds);
        e.renderer->gpuIdle();
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
    return impl->invalidate(addr, std::max<u64>(size, 1));
}

bool Rasterizer::ReadMemory(VAddr, u64) {
    // Nothing sets read watches: GPU writes go to guest memory in place.
    return false;
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

u64 Rasterizer::Flush() {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.applyPending();
    e.submit();
    return e.submits.load();
}

void Rasterizer::Finish() {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.applyPending();
    e.submit();
    if (e.backend) e.waitGpu(Engine::WaitFinish);
    if (e.renderer) e.renderer->gpuIdle();
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
            if (!VpengineXr::Available()) return false;
            VpengineXr::Start(e.backend->nativeDevice());
            started = true;
        }
        if (pipeline || pipelineFailed) return pipeline != nil;
        id<MTLDevice> dev = (__bridge id<MTLDevice>)e.backend->nativeDevice();
        NSError* error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kComposeSource) options:nil error:&error];
        MTLRenderPipelineDescriptor* pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vp_compose_vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"vp_compose_fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB;
        if (lib) pipeline = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        if (!pipeline) {
            pipelineFailed = true;
            LOG_CRITICAL(Render_Vulkan, "VPENGINE_PRESENT the compositing shader failed: {}",
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

    // The texture VPEngine has for a T#, after recording whatever fills it.
    static id<MTLTexture> textureOf(Engine& e, const vpps4::ImageDesc& d) {
        const vpgpu::TextureId tid = e.renderer->textureFor(d);
        if (!tid) return nil;
        return (__bridge id<MTLTexture>)e.backend->nativeTexture(tid);
    }

    // Draws `regions` into a new headset frame of width x height; -1 if the host has none free.
    int compose(Engine& e, u32 width, u32 height, std::span<const Region> regions) {
        u32 target_index = 0;
        void* target_texture = nullptr;
        if (!VpengineXr::Begin(width, height, target_index, target_texture)) return -1;
        const u32 slot = target_index % kSlots;
        {
            std::scoped_lock l{done_mutex};
            done[slot] = false;
        }
        id<MTLTexture> out = (__bridge id<MTLTexture>)target_texture;
        id<MTLRenderPipelineState> pso = pipeline;
        std::vector<Region> list(regions.begin(), regions.end());
        const bool queued = e.backend->encodeInterop(
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
            });
        if (!queued) {
            VpengineXr::Drop(target_index);
            return -1;
        }
        return int(slot);
    }
};

PresentState& present() {
    static PresentState& p = *new PresentState;
    return p;
}

} // namespace

namespace Present {

bool HasHeadset() {
    return VpengineXr::Available();
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
        const vpgpu::TextureId arrayTarget = e.renderer->colorTargetAt(d.address)
                                                 ? vpgpu::TextureId{}
                                                 : e.renderer->colorTargetSlice(d.address, d.width, d.height, slice);
        if (arrayTarget) {
            id<MTLTexture> t = (__bridge id<MTLTexture>)e.backend->nativeTexture(arrayTarget);
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
        // Where the eye comes from: a colour target VPEngine drew, or an image filled from guest
        // memory / written by compute (first frames and every 600).
        if (impl->frames % 600 == 0)
            LOG_INFO(Render_Vulkan, "VPENGINE_PRESENT eye {} T# {:#x} tile {} pitch {} fmt {}/{} {}x{} colour_target={} array_slice={}", k,
                     d.address, u32(d.tilingIndex), d.pitch, u32(d.dataFormat), u32(d.numFormat), d.width, d.height,
                     bool(e.renderer->colorTargetAt(d.address)), arrayTarget ? int(slice) : -1);
        // What VPEngine holds on the GPU over the eye's memory (targets inside a bigger or
        // neighbouring surface, shader-written images of another format): the eye's real producer.
        if (impl->frames % 600 == 0)
            LOG_INFO(Render_Vulkan, "VPENGINE_PRESENT eye {} overlaps:{}", k,
                     e.renderer->describeAt(d.address, u64(std::max(d.pitch, d.width)) * d.height * 4));
    }
    // The eyes' drawing is submitted first: the composition runs after it on the same queue.
    e.submit();
    if (!eyes[0] || !eyes[1]) {
        static std::atomic<u32> told{0};
        if (told++ < 4)
            LOG_WARNING(Render_Vulkan, "VPENGINE_PRESENT eye pictures missing (left {}, right {}): black frame",
                        eyes[0] != nil, eyes[1] != nil);
    }
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
        LOG_INFO(Render_Vulkan, "VPENGINE_PRESENT headset frame {}: eyes {}x{} ({} / {}), sharpen {:.2f}", impl->frames,
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
    e.submit();
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
    e.submit();
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
    VpengineXr::End(s, info);
}

bool Finished(int slot) {
    if (slot < 0) return true;
    PresentState& p = present();
    std::scoped_lock l{p.done_mutex};
    return p.done[u32(slot) % kSlots];
}

} // namespace Present

} // namespace VpengineRenderer
