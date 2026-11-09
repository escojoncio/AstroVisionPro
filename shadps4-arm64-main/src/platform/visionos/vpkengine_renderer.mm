// VPKEngine: the only renderer on visionOS (see vpkengine_renderer.h).
#include "vpkengine_renderer.h"

#import <Metal/Metal.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <os/proc.h>
#include <sys/mman.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <functional>
#include <condition_variable>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <filesystem>
#include <map>
#include <unordered_map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <span>
#include <string>
#include <thread>
#include <vector>

#include <fmt/ranges.h>
#include "common/diagnostics.h"
#include "common/elf_info.h"
#include "common/logging/log.h"
#include "common/jit_arena.h"
#include "common/path_util.h"
#include "core/libraries/videoout/buffer.h"
#include "core/address_space.h"
#include "core/memory.h"
#include "vpkengine_extent.h"
#include "vpkengine_mirror.h"
#include "vpkengine_census.h"
#include "vpkengine_xr.h"
#include "video_core/amdgpu/liverpool.h"
#include "video_core/amdgpu/pm4_exec.h"
#include "video_core/amdgpu/reg_audit.h"
#include "video_core/amdgpu/regs.h"
#include "video_core/amdgpu/resource.h"
#include "video_core/page_manager.h"
#include "video_core/recent_ranges.h"
#include "video_core/surface_metas.h"
#include "vpgpu/core/device.h"
#include "vpgpu/core/probe.h"
#include "vpgpu/metal2/metal_backend.h"
#include "vpps4/fetch.h"
#include "vpps4/formats.h"
#include "vpps4/msaa.h"
#include "vpps4/renderer.h"
#include "vpps4/scheduler.h"
#include "vpgpu/core/submit_policy.h"
#include "vpps4/report.h"
#include "video_core/shadow_pixels.h"
#include "video_core/shadow_record.h"

namespace VpkengineRenderer {
namespace {

namespace pm = vpgpu::probe;  // the probe (VPKENGINE_PROBE lines and probe-<date>.txt): on with the diagnostics mode

void shadowResolved(const vpps4::Resolved& r);  // (below: Hooks::resolved of the shadow)
void PrewarmCompose(void* nativeDevice);  // (defined with PresentState)

// Guest addresses are host addresses. Buffers alias guest memory through windows of this size
// (aligned), cut down to the mapped part around the address: one huge mapping as a single
// no-copy MTLBuffer can exceed the device's maximum buffer length. A range that crosses the end of its window
// is asked for in a window widened (in multiples of this) to hold it: see the region hook and readable().
constexpr u64 kWindow = 64ull << 20;
// The longest range the renderer asks a widened window for (gpu/ps4 kMaxGuestSpan).
constexpr u64 kMaxGuestSpan = 256ull << 20;

// vm_region_64 calls made by mappedSpan (reported by Engine::report).
std::atomic<u64> gVmRegionCalls{0};

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
        gVmRegionCalls.fetch_add(1, std::memory_order_relaxed);
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
        gVmRegionCalls.fetch_add(1, std::memory_order_relaxed);
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
// unique, so (window, span) pairs are kept for as long as the guest's map does not change. The map
// changes only through the emulator's MemoryManager (map, unmap, free, commit, decommit: each one counts
// in HostMapGeneration(), odd while it is in progress; Protect only calls mprotect, which leaves the
// maximum protection mappedSpan reads as it was, and naming / memory types do not touch the host map
// at all: they count in MappingGeneration() only) and through Map/UnmapMemory of the rasterizer
// (the PRT area is mapped without a mutation): the cache follows both, nothing else empties it.
// Answers are kept too when there is no span ("not mapped") and when the span has no mirror yet
// (asked again for the mirror only, after kMirrorRetryNs).
struct SpanCache {
    struct Entry {
        u64 from = 0, to = 0, begin = 0, end = 0;
        void* mirror = nullptr;  // the second mapping of [begin, end) the GPU buffers alias (null: none)
        u64 retryAt = 0;         // steady-clock ns after which a null mirror is asked for again (0: never)
    };
    struct Unmapped {  // `address` (a 4 KiB page of it) has no span in the window [from, to)
        u64 from = 0, to = 0, page = 0;
    };
    pm::TimedMutex<std::mutex> m{"span_cache"};
    std::array<Entry, 128> entries{};
    unsigned used = 0, next = 0, last = 0;
    std::array<Unmapped, 32> unmapped{};
    unsigned unmappedUsed = 0, unmappedNext = 0;
    u64 gen = 0;  // bumped by every emptying: a span looked up before it is not inserted after it
    // The emulator's HostMapGeneration() the entries were made at (written under the lock).
    std::atomic<u64> seen{0};
    // `gen` readable without the lock: what was checked readable at one value of it is still mapped
    // at the same value (the draw adapter keeps fetch subroutines by it, vpps4 keeps its regions).
    std::atomic<u64> mapGen{0};
    // Counters printed by Engine::report (VPKENGINE_GPU cpu region caches).
    std::atomic<u64> hits{0}, misses{0}, unmappedHits{0}, mirrorRetries{0}, bumps{0};

    static u64 emulatorGeneration() { return Core::Memory::Instance()->HostMapGeneration(); }
    void reset() {  // (under the lock)
        used = next = last = 0;
        unmappedUsed = unmappedNext = 0;
        ++gen;
        mapGen.store(gen, std::memory_order_release);
        bumps.fetch_add(1, std::memory_order_relaxed);
    }
    // (under the lock) Empties the cache if the emulator changed the map since the entries were made.
    // Read inside the lock, so that an older reading never takes over from a newer one.
    void follow() {
        const u64 now = emulatorGeneration();
        if (now == seen.load(std::memory_order_relaxed)) return;
        reset();
        seen.store(now, std::memory_order_release);
    }
    void clear() {
        std::scoped_lock l{m};
        reset();
    }
    // The generation of the guest's map, current: takes the lock only when the emulator changed it.
    u64 generation() {
        if (emulatorGeneration() != seen.load(std::memory_order_acquire)) {
            std::scoped_lock l{m};
            follow();
        }
        return mapGen.load(std::memory_order_acquire);
    }
};
SpanCache& spanCache() {
    static SpanCache& c = *new SpanCache;
    return c;
}

// A span without a mirror is asked for one again after this long (the host may refuse a vm_remap once;
// GuestMirror itself does not retry a refused range for 2 s unless its pages changed).
constexpr u64 kMirrorRetryNs = 16'000'000;
// The shadow engine (Rasterizer::Mode::Shadow) draws nothing, so no buffer aliases guest memory and no
// span gets a mirror (a vm_remap of the guest's pages): its regions point at the guest memory itself, read only.
// It is also what ShadowEndFrame answers to. Set by the rasterizer before the engine starts.
std::atomic<bool> gShadowEngine{false};
// Set by ShadowEndFrame (the flip), taken by the shadow's next Flush.
std::atomic<bool> gShadowFlip{false};
u64 steadyNs() {
    return u64(std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

// Whether any page of [begin, end) is protected for the renderer (owned or watched ranges): set by the
// rasterizer, which keeps those tables.
std::atomic<bool (*)(void*, u64, u64)> gWatchProbe{nullptr};
std::atomic<void*> gWatchProbeContext{nullptr};
// Publishes the rasterizer's tables (mapped / watched / owned ranges) as probe metrics; set with gWatchProbe.
std::atomic<void (*)(void*)> gProbeTables{nullptr};
bool spanHasWatches(u64 begin, u64 end) {
    static pm::Timer& timer = pm::timer("TIME", "span_has_watches");
    const pm::ScopedSampled scope(timer);  // (hot: calls exact, time estimated from 1 in 16)
    auto* probe = gWatchProbe.load(std::memory_order_acquire);
    return probe && probe(gWatchProbeContext.load(std::memory_order_acquire), begin, end);
}

bool cachedSpanUntimed(u64 address, u64 from, u64 to, u64& begin, u64& end, void*& mirror);
bool cachedSpan(u64 address, u64 from, u64 to, u64& begin, u64& end, void*& mirror) {
    static pm::Timer& timer = pm::timer("TIME", "cached_span");
    const pm::ScopedSampled scope(timer);  // (hot: calls exact, time estimated from 1 in 16)
    return cachedSpanUntimed(address, from, to, begin, end, mirror);
}

bool cachedSpanUntimed(u64 address, u64 from, u64 to, u64& begin, u64& end, void*& mirror) {
    SpanCache& c = spanCache();
    const bool noMirror = gShadowEngine.load(std::memory_order_relaxed);
    u64 gen0 = 0;
    bool stable = false;  // the emulator is not changing the map: what is found may be kept
    unsigned retry = ~0u;  // the entry whose null mirror is asked for again
    {
        std::scoped_lock l{c.m};
        c.follow();
        gen0 = c.gen;
        stable = !(c.seen.load(std::memory_order_relaxed) & 1);
        const auto hit = [&](const SpanCache::Entry& x) {
            return x.from == from && x.to == to && address >= x.begin && address < x.end;
        };
        unsigned found = ~0u;
        if (c.used && hit(c.entries[c.last])) {
            found = c.last;
        } else {
            for (unsigned k = 0; k < c.used; ++k)
                if (hit(c.entries[k])) {
                    c.last = found = k;
                    break;
                }
        }
        if (found != ~0u) {
            const SpanCache::Entry& x = c.entries[found];
            begin = x.begin;
            end = x.end;
            mirror = x.mirror;
            if (mirror || noMirror || steadyNs() < x.retryAt) {
                c.hits.fetch_add(1, std::memory_order_relaxed);
                return true;
            }
            retry = found;
        } else {
            for (unsigned k = 0; k < c.unmappedUsed; ++k) {
                const SpanCache::Unmapped& x = c.unmapped[k];
                if (x.from == from && x.to == to && x.page == address >> 12) {
                    c.unmappedHits.fetch_add(1, std::memory_order_relaxed);
                    return false;
                }
            }
        }
    }
    if (retry != ~0u) {
        c.mirrorRetries.fetch_add(1, std::memory_order_relaxed);
        mirror = GuestMirror(begin, end);
        std::scoped_lock l{c.m};
        c.follow();
        SpanCache::Entry& x = c.entries[retry];
        if (c.gen == gen0 && x.from == from && x.to == to && x.begin == begin) {
            x.mirror = mirror;
            x.retryAt = mirror ? 0 : steadyNs() + kMirrorRetryNs;
        }
        return true;
    }
    c.misses.fetch_add(1, std::memory_order_relaxed);
    bool spanFound;
    {
        static pm::Timer& walk = pm::timer("TIME", "mapped_span_walk");  // the vm_region_64 walk of a miss
        const pm::Scoped walkScope(walk);
        spanFound = mappedSpan(address, from, to, begin, end);
    }
    if (!spanFound) {
        if (stable) {
            std::scoped_lock l{c.m};
            c.follow();
            if (c.gen == gen0) c.unmapped[c.unmappedUsed < c.unmapped.size() ? c.unmappedUsed++ : (c.unmappedNext++ % c.unmapped.size())] = {from, to, address >> 12};
        }
        return false;
    }
    // The span's mirror (made once per span; a span without one is asked again, see kMirrorRetryNs).
    mirror = noMirror ? nullptr : GuestMirror(begin, end);
    std::scoped_lock l{c.m};
    c.follow();
    if (!stable || c.gen != gen0) return true;  // the map changed meanwhile: use it this once, keep it out
    const unsigned k = c.used < c.entries.size() ? c.used++ : (c.next++ % unsigned(c.entries.size()));
    c.entries[k] = {from, to, begin, end, mirror, mirror || noMirror ? 0 : steadyNs() + kMirrorRetryNs};
    c.last = k;
    return true;
}

// Bytes readable from `address` on (up to `want`), 0 if it is not mapped. A range that runs past its window is
// looked for in a window widened to hold it (as the region hook does), so that mapped memory across the
// boundary counts as readable.
u64 readable(u64 address, u64 want) {
    const u64 from = address & ~(kWindow - 1);
    // (the widening is bounded like the renderer's: a longer range is looked for in the window that reaches 256 MiB past
    // `address`, and the answer says how much of it is there)
    const u64 reach = std::min<u64>(want, kMaxGuestSpan);
    const u64 to = reach && address + reach > address ? std::max(from + kWindow, (address + reach + kWindow - 1) & ~(kWindow - 1))
                                                      : from + kWindow;
    u64 begin, end;
    void* mirror = nullptr;
    if (!cachedSpan(address, from, to, begin, end, mirror)) return 0;
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
vpgpu::metal2::MslShader toMetal(const vpmsl::MslShader& s) {
    vpgpu::metal2::MslShader m;
    m.source = s.source;
    m.entry = "vp_main";
    m.argumentBufferIndex = 0;
    m.threadsPerGroup = s.workgroupSize;
    m.colorOutputs = s.colorOutputs;
    for (const vpmsl::Argument& a : s.arguments)
        m.arguments.push_back({vpgpu::BindKind(uint8_t(a.kind) + 1), uint16_t(a.index), a.offset});
    return m;
}

void flushLeftOut();  // defined below, with the counters it drains
void publishLeftOut();  // probe: the draws left out before the renderer, by reason (below, with the table)
void publishProcess();  // probe: the process's memory, heap, threads and CPU
void publishDisk(const std::filesystem::path& cacheDir);  // probe: the persistent caches on disk

// The engine: VPKEngine's Metal backend, device and PS4 renderer, shared by the rasterizer (GPU
// thread) and the presenter. Everything that records goes under `lock`.
struct Engine {
    // Recursive: a CPU access to memory an image on the GPU is ahead of faults inside code that
    // holds the lock already (a DMA done on the CPU); the fault handler writes the image back.
    pm::TimedMutex<std::recursive_mutex> lock{"engine"};
    vpgpu::metal2::ShaderTable shaders;
    std::unique_ptr<vpgpu::metal2::MetalBackend> backend;
    // The shadow's backend (instead of `backend`): it takes the recorded frames and drops them.
    std::unique_ptr<vpgpu::NullBackend> nullBackend;
    // Set by the rasterizer before start(): this engine is the shadow's (Rasterizer::Mode::Shadow). It has no GPU,
    // no watchdog, no submit thread, and writes no guest memory: DMA, write backs, labels, occlusion results and
    // WRITE_DATA are left to the real renderer, the rasterizer's methods for them do nothing here.
    bool shadow = false;
    std::unique_ptr<vpgpu::Device> device;
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
    // Unmapped ranges: the surface metadata registered there is forgotten (applied with the invalidations, under the
    // engine lock that `metas` is under; UnmapMemory cannot take it).
    std::vector<std::pair<u64, u64>> pendingUnmaps;
    void queueUnmap(u64 a, u64 n) {
        while (pendingLock.test_and_set(std::memory_order_acquire)) {}
        pendingUnmaps.push_back({a, n});
        pendingLock.clear(std::memory_order_release);
    }
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
        std::vector<std::pair<u64, u64>> unmapped;
        unmapped.swap(pendingUnmaps);
        const bool all = pendingAll;
        pendingAll = false;
        pendingLock.clear(std::memory_order_release);
        for (auto [a, n] : unmapped) metas.EraseRange(a, a + n);
        for (auto [a, n] : unmapped) {
            const u64 lo = a, hi = a + n;
            std::erase_if(htileDepths, [lo, hi](const auto& h) { return h.first >= lo && h.first < hi; });
        }
        if (!renderer) return;
        if (all) {
            // Which ranges the CPU wrote is unknown: images ahead of memory are written back (and the GPU waited
            // for) first, so marking everything CPU-written does not drop the content only they hold.
            // (The shadow writes nothing back: its images stay ahead of memory.)
            if (!shadow) {
                if (scheduler) syncForDma(0, ~u64(0), 0, 0, "invalidate_all");
                else renderer->syncToMemory(0, ~u64(0));
            }
            renderer->invalidate(0, ~u64(0));
            if (scheduler) scheduler->forgetLabelValues(0, ~u64(0));
        }
        for (auto [a, n] : work) {
            renderer->invalidate(a, n);
            // (the CPU rewrote it: a queued label value no longer says what a wait finds there)
            if (scheduler) scheduler->forgetLabelValues(a, n);
        }
    }
    std::atomic<bool> failed{false};  // (the Tee reads it from other threads)
    u64 dmaUnsynced = 0, dmaSynced = 0;  // DMA packets done on the CPU without / after a GPU wait
    u64 dmaOnGpu = 0;                    // DMA packets recorded on the GPU timeline instead (Scheduler::dmaOnGpu)
    u64 labelsImmediate = 0;             // labels written when processed, not after the GPU (ScheduleLabelWrite)

    // Fast clear metadata (CMASK / HTILE) of the targets drawn so far, under `lock` (the same semantics as the
    // Vulkan backend's TextureCache::surface_metas). The host keeps no compression metadata: a title that
    // clears a target by writing its metadata gets a real clear before the next draw into the target.
    VideoCore::SurfaceMetas metas;
    // The depth buffer each HTILE belongs to (the base of its Z plane and DB_DEPTH_CLEAR at its last draw): a clear of the
    // HTILE is told to the renderer, which gives the clear value to a texture of that surface no depth target serves (the
    // hardware reads the value through the HTILE; memory was never written). Under `lock`.
    struct HtileDepth {
        VAddr z = 0;
        float clear = 1.0f;
    };
    std::unordered_map<VAddr, HtileDepth> htileDepths;
    void noteHtileCleared(VAddr htile) {
        if (!renderer) return;
        if (const auto it = htileDepths.find(htile); it != htileDepths.end()) renderer->depthCleared(it->second.z, it->second.clear);
    }
    // Totals for the "vpps4.meta" line: metadata cleared by a compute shader / by DMA, FCE passes that found
    // the target still cleared, clears applied (colour, depth) and the RectList draws that carried them out.
    u64 metaCs = 0, metaDma = 0, metaEliminates = 0, metaColorClears = 0, metaDepthClears = 0, metaClearDraws = 0;
    // Probe counters of the fast clear metadata (under `lock`): draws into a target with CMASK / HTILE, and those whose clear
    // words do not decode to a colour (the title's fast clear is then not applied).
    u64 probeCmaskDraws = 0, probeCmaskUndecodable = 0, probeHtileDraws = 0, probeFmaskDraws = 0;
    // Pictures composed for the headset (ComposeEyes), and the folder the persistent caches are in (probe: disk size).
    std::atomic<u64> pictures{0};
    std::filesystem::path probeCacheDir;
    std::chrono::steady_clock::time_point probeDiskAt{}, probeSummaryAt = std::chrono::steady_clock::now();

    // CPU time of the GPU thread, in ns, printed every ~2 s (VPKENGINE_GPU cpu:). Atomics: the
    // presenter submits too, and draw timers stop after the engine lock is released.
    using Clock = std::chrono::steady_clock;
    std::atomic<u64> adapterNs{0}, adapterCalls{0};
    Clock::time_point lastReport = Clock::now();
    static u64 nsSince(Clock::time_point t) {
        return u64(std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now() - t).count());
    }
    struct Timer {
        std::atomic<u64>& to;
        Clock::time_point t0 = Clock::now();
        ~Timer() {
            const u64 ns = nsSince(t0);
            to.fetch_add(ns, std::memory_order_relaxed);
            if (pm::enabled()) {
                static pm::Hist& adapter = pm::hist("TIME", "draw_adapter_us");  // one Draw / Dispatch of the adapter, whole call
                adapter.add(ns / 1000);
            }
        }
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
    // A DMA that syncForDma left to the GPU timeline was recorded.
    void noteDmaOnGpu() {
        ++dmaOnGpu;
        scheduler->noteDmaRecorded();
    }
    // `caller` names who asks (probe DMASYNC). With `gpuOk` (FillBuffer / CopyBuffer) it returns true, without waiting, when queued
    // GPU work touches the range: the DMA is then recorded on the GPU timeline by the caller (VPKENGINE_DMA_CPU=1 turns that off).
    bool syncForDma(u64 a, u64 n, u64 b = 0, u64 m = 0, const char* caller = "", bool gpuOk = false) {
        static pm::Timer& timer = pm::timer("TIME", "sync_for_dma");
        const pm::Scoped scope(timer);
        // Images ahead of the memory the CPU is about to read or write are written back first (the
        // copies it records count as queued GPU work on those ranges: submitted and waited for below).
        // (probe: the parts of the call, and a SYNCDMA_SLOW line for a call over 50 ms: write-back of images, the GPU-timeline
        // decision, the CPU wait)
        const bool probing = pm::enabled();
        const Clock::time_point t0 = probing ? Clock::now() : Clock::time_point{};
        const bool written = renderer->syncToMemory(a, n);
        const bool writtenB = m && renderer->syncToMemory(b, m);
        const u64 toMemoryNs = probing ? nsSince(t0) : 0;
        const Clock::time_point t1 = probing ? Clock::now() : Clock::time_point{};
        const bool onGpu = gpuOk && (m ? scheduler->dmaOnGpu(b, m, a) : scheduler->dmaOnGpu(a, n));
        const u64 onGpuNs = probing ? nsSince(t1) : 0;
        const Clock::time_point t2 = probing ? Clock::now() : Clock::time_point{};
        const bool waited = !onGpu && scheduler->syncCpu(a, n, vpgpu::SubmitReason::Dma, b, m, caller);
        // (a small range the CPU had to wait for: buffers bound from it are copied at their draw from now on, so the next
        // write of it in order with the draws, DUMP_CONST_RAM / WRITE_DATA / a small DMA once a picture, waits for nothing)
        if (waited && n <= 4096) renderer->cpuAccessed(a, n);
        if (waited && m && m <= 4096) renderer->cpuAccessed(b, m);
        if (probing) {
            const u64 cpuNs = nsSince(t2);
            static pm::Timer& tMem = pm::timer("TIME", "sync_for_dma_to_memory");
            static pm::Timer& tGpu = pm::timer("TIME", "sync_for_dma_on_gpu_check");
            static pm::Timer& tCpu = pm::timer("TIME", "sync_for_dma_cpu_wait");
            tMem.add(toMemoryNs), tGpu.add(onGpuNs), tCpu.add(cpuNs);
            static u64 slow = 0;
            if (const u64 total = nsSince(t0); total > 50'000'000ull && (++slow <= 200 || slow % 50 == 0))
                LOG_INFO(Render_Vulkan,
                         "VPKENGINE_PROBE SYNCDMA_SLOW n={} caller={} a={:#x} n_bytes={} b={:#x} m={} gpu_ok={} on_gpu={} written={}{} "
                         "to_memory_ms={:.2f} on_gpu_check_ms={:.2f} cpu_wait_ms={:.2f} total_ms={:.2f} waited={}",
                         slow, caller, a, n, b, m, int(gpuOk), int(onGpu), int(written), int(writtenB), toMemoryNs / 1e6,
                         onGpuNs / 1e6, cpuNs / 1e6, total / 1e6, int(waited));
        }
        if (onGpu) return true;
        if (waited || written || writtenB) ++dmaSynced;
        else ++dmaUnsynced;
        return false;
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
        LOG_INFO(Render_Vulkan,
                 "VPKENGINE_GPU cpu bind phases (ms/s): descriptor read {:.1f}, texture lookup/refresh {:.1f}, buffer lookup {:.1f}, "
                 "constant copy+memcmp {:.1f}, uploads {:.1f}, argument table/other {:.1f}",
                 t.bindDescMs / s, t.bindTexMs / s, t.bindBufMs / s, t.bindCbMs / s, t.bindUploadMs / s,
                 (t.bindMs - t.bindDescMs - t.bindTexMs - t.bindBufMs - t.bindCbMs - t.bindUploadMs) / s);
        {
            // What "frame compile+submit" is made of. The backend's submit is in it only when it runs on the
            // caller's thread (without VPK_SUBMIT_THREAD); `other` is the rest (queue space for the submit thread).
            const double backendInSubmit = device->asyncSubmit() ? 0.0 : t.backendMs;
            LOG_INFO(Render_Vulkan,
                     "VPKENGINE_GPU cpu submit phases (ms/s): life.plan {:.1f}, hold for pipelines {:.1f} ({:.0f} frames/s, {:.0f}/s gave up "
                     "at the budget), frame compile {:.1f}, backend submit {:.1f} (waiting for a frame slot {:.1f}){}, other {:.1f}",
                     t.lifeMs / s, t.holdMs / s, double(t.holdFrames) / s, double(t.holdTimeouts) / s, t.compileMs / s,
                     t.backendMs / s, t.slotWaitMs / s, device->asyncSubmit() ? " [submit thread: not in compile+submit]" : "",
                     (t.submitMs - t.lifeMs - t.holdMs - t.compileMs - backendInSubmit) / s);
        }
        {
            SpanCache& sc = spanCache();
            // (what began a mutation of the emulator's map in this interval: the first six move the span cache's
            // generation, the last three only MappingGeneration())
            std::string mutations;
            {
                const auto counts = Core::Memory::Instance()->TakeMapMutationCounts();
                for (size_t k = 0; k < counts.size(); ++k)
                    mutations += fmt::format("{}{} {:.0f}", k ? ", " : "", Core::MemoryManager::MapMutationName(k),
                                             double(counts[k]) / s);
            }
            const VpkengineRenderer::GuestMirrorStats ms = VpkengineRenderer::TakeGuestMirrorStats();
            const u64 spHits = take(sc.hits), spMisses = take(sc.misses), spUnmapped = take(sc.unmappedHits);
            const u64 spRetries = take(sc.mirrorRetries), spVm = take(gVmRegionCalls), spBumps = take(sc.bumps);
            if (pm::enabled()) {
                pm::counter("APP", "span_hits").add(spHits), pm::counter("APP", "span_misses").add(spMisses);
                pm::counter("APP", "span_unmapped_hits").add(spUnmapped), pm::counter("APP", "span_mirror_retries").add(spRetries);
                pm::counter("APP", "vm_region_calls").add(spVm), pm::counter("APP", "span_cache_emptied").add(spBumps);
                pm::counter("APP", "mirror_lookups").add(ms.lookups), pm::counter("APP", "mirror_region_calls").add(ms.regionCalls);
                pm::counter("APP", "region_hits").add(t.regionHits), pm::counter("APP", "region_misses").add(t.regionMisses);
            }
            LOG_INFO(Render_Vulkan,
                     "VPKENGINE_GPU cpu region caches (per s): cachedSpan {:.0f} hits, {:.0f} misses, {:.0f} unmapped hits, "
                     "{:.0f} mirror retries; vm_region_64 {:.0f}, vm_region_recurse_64 {:.0f} ({:.0f} GuestMirror lookups); "
                     "span cache emptied {:.0f}; vpps4 region cache {:.0f} hits, {:.0f} misses; map mutations (per s): {}",
                     double(spHits) / s, double(spMisses) / s, double(spUnmapped) / s,
                     double(spRetries) / s, double(spVm) / s, double(ms.regionCalls) / s,
                     double(ms.lookups) / s, double(spBumps) / s, double(t.regionHits) / s,
                     double(t.regionMisses) / s, mutations);
        }
        if (scheduler) LOG_INFO(Render_Vulkan, "VPKENGINE_GPU {}", scheduler->takeSummary());
        if (pm::enabled()) probeSample(t, s, calls);
    }

    // ---- Probe (VPKENGINE_PROBE): every metric family, once per report() interval (~2 s). Under `lock`, from the submit hook.
    // The engine and the backend publish their own state (Renderer / Device / MetalBackend::publishProbe); this adds what only
    // the app knows: the CPU times of the renderer, the adapter's caches, the fast clear metadata, the process.
    void probeSample(const vpps4::CpuTimes& t, double dt, u64 adapterCalls_) {
        static pm::Timer& lockedTimer = pm::timer("TIME", "probe_sample_locked");  // (what the sampling costs the thread that draws)
        const pm::Scoped lockedScope(lockedTimer);
        const auto tm = [](const char* name, double ms, u64 calls) { pm::timer("TIME", name).addMs(ms, std::max<u64>(calls, 1)); };
        tm("renderer_draw", t.drawMs, t.calls), tm("shader_lookup", t.shaderMs, t.calls), tm("bind", t.bindMs, t.calls);
        tm("bind_descriptors", t.bindDescMs, t.calls), tm("bind_textures", t.bindTexMs, t.calls), tm("bind_buffers", t.bindBufMs, t.calls);
        tm("bind_constants", t.bindCbMs, t.calls), tm("bind_uploads", t.bindUploadMs, t.calls);
        tm("bind_table_other", t.bindMs - t.bindDescMs - t.bindTexMs - t.bindBufMs - t.bindCbMs - t.bindUploadMs, t.calls);
        tm("pipeline_request", t.pipelineMs, t.calls), tm("submit_total", t.submitMs, t.submits);
        tm("life_plan", t.lifeMs, t.submits), tm("hold_pipelines", t.holdMs, t.holdFrames), tm("frame_compile", t.compileMs, t.submits);
        tm("backend_submit", t.backendMs, t.submits), tm("slot_wait", t.slotWaitMs, t.submits);
        tm("encode_and_commit", t.backendMs - t.slotWaitMs, t.submits);  // (the backend's submit without the wait for a frame slot)
        pm::counter("RATES", "adapter_calls").add(adapterCalls_);
        pm::counter("RATES", "submits").set(submits.load());
        pm::counter("RATES", "empty_submits").add(t.emptySubmits);
        pm::counter("RATES", "user_data_reused").add(t.userDataReused);
        pm::counter("RATES", "aligned_copy_reused").add(t.alignedCopyReused);
        pm::counter("RATES", "resolve_dest_clear_dropped").add(t.resolveDestClearDropped);
        pm::counter("RATES", "resolve_dest_clear_flushed").add(t.resolveDestClearFlushed);
        pm::counter("RATES", "dma_unsynced").set(dmaUnsynced), pm::counter("RATES", "dma_synced").set(dmaSynced);
        pm::counter("RATES", "dma_on_gpu").set(dmaOnGpu);
        pm::counter("RATES", "labels_immediate").set(labelsImmediate);
        pm::counter("RATES", "headset_frames").set(pictures.load());
        pm::gauge("RATES", "interval_s").set(dt);
        // Fast clears (CMASK / HTILE): a clear whose words do not decode is not applied (the target keeps its contents).
        pm::counter("FASTCLEAR", "cmask_draws").set(probeCmaskDraws), pm::counter("FASTCLEAR", "cmask_undecodable").set(probeCmaskUndecodable);
        pm::counter("FASTCLEAR", "fmask_draws").set(probeFmaskDraws), pm::counter("FASTCLEAR", "htile_draws").set(probeHtileDraws);
        pm::counter("FASTCLEAR", "cs_meta_writes").set(metaCs), pm::counter("FASTCLEAR", "dma_meta_writes").set(metaDma);
        pm::counter("FASTCLEAR", "eliminates").set(metaEliminates), pm::counter("FASTCLEAR", "color_clears").set(metaColorClears);
        pm::counter("FASTCLEAR", "depth_clears").set(metaDepthClears), pm::counter("FASTCLEAR", "clear_draws").set(metaClearDraws);
        pm::gauge("FASTCLEAR", "meta_surfaces").set(double(metas.Size()));
        // Caches and queues of the adapter
        pm::gauge("APP", "target_extents").set(double(extents.Size()));
        {
            SpanCache& sc = spanCache();
            std::scoped_lock l{sc.m};
            pm::gauge("APP", "span_entries").set(sc.used), pm::gauge("APP", "span_unmapped_entries").set(sc.unmappedUsed);
        }
        while (pendingLock.test_and_set(std::memory_order_acquire)) {}
        pm::gauge("APP", "pending_invalidations").set(double(pending.size()));
        pm::gauge("APP", "pending_unmaps").set(double(pendingUnmaps.size()));
        pm::gauge("APP", "pending_all").set(pendingAll ? 1 : 0);
        pendingLock.clear(std::memory_order_release);
        pm::gauge("APP", "error_lines").set(double(errorLines.load()));
        publishLeftOut();
        if (auto* tables = gProbeTables.load(std::memory_order_acquire)) tables(gWatchProbeContext.load(std::memory_order_acquire));
        const auto now = Clock::now();
        const bool disk = probeDiskAt == Clock::time_point{} || now - probeDiskAt >= std::chrono::seconds{30};
        if (disk) probeDiskAt = now;
        renderer->publishProbe(pictures.load());
        if (device) device->publishProbe();
        if (backend) backend->publishProbe();
        const bool summary = now - probeSummaryAt >= std::chrono::seconds{60};
        if (summary) probeSummaryAt = now;
        // The rest runs on a thread of its own, off the engine lock (the registry has its own mutex): the process and disk
        // figures, the sample (every metric to the CSV, the compact lines to the log) and the summary. It stalled the thread
        // that draws, and whoever waited for the engine lock, once every interval.
        std::thread([disk, summary, dir = probeCacheDir] {
            publishProcess();
            if (disk) publishDisk(dir);
            std::vector<std::string> compact;
            pm::registry().sample(&compact);
            for (const std::string& line : compact) LOG_INFO(Render_Vulkan, "{}", line);
            if (summary)
                for (const std::string& line : pm::registry().summary()) LOG_INFO(Render_Vulkan, "{}", line);
        }).detach();
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

    // Probe: on with the diagnostics mode; the CSV (one row per interval, one column per metric) goes next to the logs.
    void probeStart() {
        if (!Common::Diagnostics()) return;
        pm::setEnabled(true);
        std::filesystem::path dir;
        if (const char* d = std::getenv("SHADPS4_PROBE_DIR"); d && *d) dir = d;
        else dir = Common::FS::GetUserPath(Common::FS::PathType::LogDir);
        std::error_code ec;
        std::filesystem::create_directories(dir, ec);
        char stamp[32];
        const std::time_t now = std::time(nullptr);
        std::tm tmv{};
        localtime_r(&now, &tmv);
        std::strftime(stamp, sizeof stamp, "%Y-%m-%d_%H-%M-%S", &tmv);
        const std::filesystem::path file = dir / (std::string("probe-") + stamp + ".txt");
        if (pm::registry().openCsv(file.string()))
            LOG_INFO(Render_Vulkan, "VPKENGINE_PROBE csv {}", file.string());
        else
            LOG_WARNING(Render_Vulkan, "VPKENGINE_PROBE csv {} could not be opened: the lines are logged only", file.string());
        // The system's memory pressure warnings (a jetsam kill gives the process no notice: the last of these, with the memory
        // left, is what the log can show before it).
        static dispatch_source_t pressure = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
            DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        if (pressure) {
            dispatch_source_set_event_handler(pressure, ^{
                const unsigned long level = dispatch_source_get_data(pressure);
                LOG_WARNING(Render_Vulkan, "VPKENGINE_PROBE MEMPRESSURE level={} available_mb={}",
                            level & DISPATCH_MEMORYPRESSURE_CRITICAL ? "critical"
                            : level & DISPATCH_MEMORYPRESSURE_WARN  ? "warn"
                                                                    : "normal",
                            u64(os_proc_available_memory()) >> 20);
            });
            dispatch_resume(pressure);
        }
    }

    bool start() {
        if (renderer || failed) return renderer != nullptr;
        probeStart();
        // One GPU frame per presented picture (vpps4::Scheduler accumulates the ~15 Liverpool command
        // buffers of a picture). The picture's frame and the headset's compose (encodeInterop) each hold a frame
        // slot until the GPU finishes them, so with two the next picture's submit waits for the previous one to
        // finish; three let the recording thread run one picture ahead (one picture more of latency, which the
        // headset's reprojection hides). VPKENGINE_FRAMES_IN_FLIGHT=2..6 (vpps4's upload rings, 8, cover up to 6).
        vpgpu::metal2::MetalOptions options;
        options.framesInFlight = 3;
        options.renderCache = true;  // PS4 draws repeat state and table buffers; VPKENGINE_RENDER_CACHE=0 turns it off (A/B)
        if (const char* v = std::getenv("VPKENGINE_FRAMES_IN_FLIGHT"); v && *v)
            options.framesInFlight = unsigned(std::clamp(std::atoi(v), 2, 6));
        if (!shadow) LOG_INFO(Render_Vulkan, "VPKENGINE_GPU frames in flight {}", options.framesInFlight);
        // What the engine keeps between runs, in the cache folder the app points the emulator at
        // (the VPS4 folder's Cachés), one folder per game: the Metal pipeline archive, the
        // translated shaders and the list of pipelines built (compiled ahead at the next start).
        const std::string serial{Common::ElfInfo::Instance().GameSerial()};
        const std::filesystem::path cacheDir =
            Common::FS::GetUserPath(Common::FS::PathType::CacheDir) / "vpkengine" / (serial.empty() ? "unknown" : serial);
        if (!shadow) {
            std::error_code ec;
            std::filesystem::create_directories(cacheDir / "metal", ec);
            if (!ec) options.cacheRoot = cacheDir / "metal";
        }
        probeCacheDir = cacheDir;
        vpgpu::Backend* base = nullptr;
        if (shadow) {
            // No GPU: the null backend takes the frames and drops them. It keeps no history (it would grow for as long
            // as the game runs) and finishes each frame as it is submitted.
            nullBackend = std::make_unique<vpgpu::NullBackend>();
            nullBackend->record = false;
            nullBackend->autoComplete = true;
            base = nullBackend.get();
            // What the device reports, as in the other mode (the formats it plans are compared with the real renderer's).
            vpps4::FormatCaps fc;
            id<MTLDevice> mtl = MTLCreateSystemDefaultDevice();
            fc.bc = mtl != nil && [mtl supportsBCTextureCompression];
            vpps4::setFormatCaps(fc);
        } else {
            backend = std::make_unique<vpgpu::metal2::MetalBackend>(shaders, [this](const std::string& l) { log(l); },
                                                                   options);
            if (!backend->ok()) {
                failed = true;
                LOG_CRITICAL(Render_Vulkan, "VPKENGINE_GPU no Metal device: nothing can be drawn");
                return false;
            }
            // What the host can sample natively decides the texture plans (BC is absent on visionOS): set before
            // the first draw builds one.
            vpps4::FormatCaps fc;
            fc.bc = backend->caps().bc;
            vpps4::setFormatCaps(fc);
            base = backend.get();
        }
        // (the shadow's pipelines are "built" by the null backend on the spot: no compile workers)
        device = std::make_unique<vpgpu::Device>(*base, shadow ? 0 : 2, [this](const std::string& l) { log(l); });
        // A guest window the backend cannot wrap (no-copy) has no buffer: the renderer must get no id for it, not one that
        // reads as address 0.
        device->setRefuseFailedBuffers(true);
        // The PS4 hold regime (core's default is the single-budget one with back-off, opt-in here): the first 120
        // frames (or 10 s held) wait up to the whole hold (1500 ms, VP_HOLD_MS) for every pipeline, afterwards draws
        // wait 12 ms and a draw whose pipeline is not ready is left out of that frame only; Dispatch work keeps the
        // whole hold. VPKENGINE_HOLD_MS / VPKENGINE_HOLD_WARMUP_FRAMES (read by the Device) still override these.
        if (const char* e = std::getenv("VPKENGINE_HOLD_MS"); !e || !*e) device->setHoldSteadyMs(12);
        if (const char* e = std::getenv("VPKENGINE_HOLD_WARMUP_FRAMES"); !e || !*e) device->setHoldWarmupFrames(120);
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
        // vpps4 keeps the mirrored regions this hook returns until the guest's map changes.
        hooks.regionGeneration = [] { return spanCache().generation(); };
        hooks.explainAddress = [](uint64_t address) { return ExplainAddress(address); };
        // (the shadow has no Metal to give the shaders to; they are still translated)
        if (!shadow) hooks.shader = [this](uint64_t id, vpir::Stage, const vpmsl::MslShader& s) { shaders.add(id, toMetal(s)); };
        hooks.log = [this](const std::string& l) { log(l); };
        // The shadow tells the Tee's comparison what the renderer resolved for each call (shadow_record.h).
        if (shadow) hooks.resolved = [](const vpps4::Resolved& r) { shadowResolved(r); };
        hooks.watchWrites = [this](uint64_t a, uint64_t n) {
            if (watchWrites) watchWrites(a, n);
        };
        hooks.watchOwned = [this](uint64_t a, uint64_t n, bool on) {
            if (watchOwned) watchOwned(a, n, on);
        };
        // Views of images (another format of the same texel size, a layer range, a cube / array):
        // lazily resolved handles of the Metal backend. (The shadow has none: the renderer falls back to the
        // image itself and counts a note.)
        if (!shadow) {
            hooks.view = [this](const vpps4::ViewRequest& r) -> vpgpu::TextureId {
                vpgpu::metal2::MetalBackend::ViewDesc d;
                d.type = r.type;
                d.array = r.array;
                d.format = r.format;
                d.baseLayer = r.baseLayer;
                d.layers = r.layers;
                d.baseMip = r.baseMip;
                d.mips = r.mips;  // 0: every level from baseMip (the backend resolves it against the base)
                return backend->createView(r.base, d);
            };
            hooks.destroyView = [this](vpgpu::TextureId v) { backend->destroyView(v); };
        }
        // A compute shader that writes metadata without address arithmetic (no xor) clears it: the dispatch is left
        // out and the metadata marked cleared. One that reads metadata is a copy shader and runs.
        // (not asked while no target has metadata: the renderer then prepares nothing for it)
        hooks.computeBuffersWanted = [this] { return !metas.Empty(); };
        hooks.computeBuffers = [this](std::span<const vpps4::ComputeBuffer> buffers, bool usesXor, bool complete) {
            if (!complete) return false;  // (it may touch memory the span does not say: it runs)
            for (const vpps4::ComputeBuffer& b : buffers)
                if (!b.written && metas.IsMeta(b.address)) return false;
            if (usesXor) return false;
            for (const vpps4::ComputeBuffer& b : buffers)
                if (b.written && metas.ClearAll(b.address)) {
                    ++metaCs;
                    noteHtileCleared(b.address);
                    return true;
                }
            return false;
        };
        // Opt-in (VPK_SUBMIT_THREAD=1): frame encoding on its own thread. Not on by default: the Metal
        // backend was written for one thread that creates resources and submits.
        if (const char* t = std::getenv("VPK_SUBMIT_THREAD"); !shadow && t && *t && *t != '0') device->startSubmitThread(2);
        // What vpps4 skips / approximates / cannot translate goes to the census.
        vpps4::setReportSink([](void*, const char* cat, const char* key, const char* detail, u64 count) {
            Census::NoteN(cat ? cat : "vpps4", key ? key : "", detail ? detail : "", count);
        });
        renderer = std::make_unique<vpps4::Renderer>(*device, std::move(hooks));
        renderer->setSummaryEvery(kEvery);
        // A label without an interrupt waits up to 12 ms on unsubmitted work (the default is 6): every such submit ends the
        // GPU frame (a pass cut and a trip through the encoder under the engine lock), and at 25 pictures a second the title
        // got four of them a picture. VPKENGINE_LABEL_GRACE_MS sets it.
        vpgpu::SubmitPolicy policy;
        policy.labelGraceMs = 12;
        if (const char* v = std::getenv("VPKENGINE_LABEL_GRACE_MS"); v && *v) policy.labelGraceMs = std::max(1.0, std::atof(v));
        scheduler = std::make_unique<vpps4::Scheduler>(*renderer, *device, policy, [] { return msNow(); });
        scheduler->setSubmitHook([this] {
            ++submits;
            if (pm::enabled()) {  // the time between one picture's submit and the next: the guest's frame time
                static pm::Hist& frame = pm::hist("TIME", "guest_frame_us");
                static std::atomic<u64> previous{0};
                const u64 at = steadyNs();
                if (const u64 before = previous.exchange(at, std::memory_order_relaxed)) frame.add((at - before) / 1000);
            }
            if (submits % kEvery == 1)
                LOG_INFO(Render_Vulkan, "VPKENGINE_GPU dma: {} packets without a GPU wait, {} after one, {} on the GPU timeline (so far)",
                         dmaUnsynced, dmaSynced, dmaOnGpu);
            renderer->drainOcclusion(false);  // ZPASS_DONE results of frames that finished
            if (submits % 600 == 1) {
                const auto& handled = renderer->stats().handled;
                const auto rect = handled.find("rect list clear");
                const u64 rectDraws = rect == handled.end() ? 0 : rect->second;
                LOG_INFO(Render_Vulkan,
                         "VPKENGINE_GPU vpps4.meta cs_meta_writes={} dma_meta_writes={} eliminates={} color_clears={} "
                         "depth_clears={} rect_list_clears={} (totals)",
                         metaCs, metaDma, metaEliminates, metaColorClears, metaDepthClears,
                         rectDraws > metaClearDraws ? rectDraws - metaClearDraws : 0);
            }
            flushLeftOut();
            report();
        });
        if (!shadow) {  // (the shadow has no labels to hurry: the Flush of its batches applies the policy)
            watchdog = std::thread([this] { watchdogLoop(); });
            watchdog.detach();
        }
        // MSAA: the game's targets keep their sample count up to the app's limit (SHADPS4_MAX_MSAA,
        // 1/2/4, default 4; Apple GPUs stop at 4). 1 turns it off: the targets become single-sample
        // and the game's resolves become copies. Foveation (SHADPS4_GAME_FOVEATION=1, default off)
        // is exclusive with MSAA: a pass that has both draws without foveation.
        int maxMsaa = 4;
        if (const char* v = std::getenv("SHADPS4_MAX_MSAA")) maxMsaa = std::clamp(std::atoi(v), 1, 4);
        renderer->setMaxSamples(uint8_t(maxMsaa));
        const char* fov = std::getenv("SHADPS4_GAME_FOVEATION");
        renderer->setFoveation(fov && std::atoi(fov) != 0);
        if (!shadow) renderer->setCacheRoot(cacheDir / "vpps4");
        LOG_INFO(Render_Vulkan, "VPKENGINE_GPU persistent caches in {}", cacheDir.string());
        if (shadow) {
            LOG_INFO(Render_Vulkan, "VPKENGINE_GPU shadow renderer on (null backend: no GPU, no guest memory written)");
            return true;
        }
        LOG_INFO(Render_Vulkan, "VPKENGINE_GPU renderer on (VPKEngine draws everything in Metal; no Vulkan device)");
        // Off the first frame's path: the headset compositing shader is compiled meanwhile.
        if (VpkengineXr::Available()) PrewarmCompose(backend->nativeDevice());
        return true;
    }

    // Hands the recorded work to the GPU now (the picture is presented).
    void present() {
        if (scheduler) scheduler->present();
    }

    // Draw probes (EYE_CHAIN / EYE_GS / EYE_PS): armed for a picture, the renderer records what its draws
    // sampled and expanded; the guest-level resolves of that picture are noted here. Under `lock`.
    struct ResolveNote {
        u64 address;
        u32 width, height, pitch;
    };
    bool probeArmed = false;
    std::vector<ResolveNote> resolves;
    // The size each colour target was set up with, by address (see vpkengine_extent.h). Under `lock`.
    VpkengineRenderer::TargetExtents extents;
    void armProbes(bool on) {
        if (!renderer) return;
        probeArmed = on;
        renderer->setProbes(on);
        resolves.clear();
    }
};

Engine& engine() {
    static Engine& e = *new Engine;  // never destroyed: the rasterizer may outlive statics
    return e;
}

// The VPKEngine half of the Tee's record (null outside the shadow's Tee calls).
VideoCore::Shadow::Side* shadowSide() {
    VideoCore::Shadow::Record* record = VideoCore::Shadow::Current();
    return record != nullptr ? &record->vpk : nullptr;
}

// A call starts: left out until the renderer says otherwise.
VideoCore::Shadow::Side* shadowBegin(const char* reason) {
    VideoCore::Shadow::Side* side = shadowSide();
    if (side) {
        *side = {};
        side->status = VideoCore::Shadow::Status::Skipped;
        side->reason = reason;
    }
    return side;
}

VideoCore::Shadow::Stage shadowStage(uint8_t s) {
    using Stage = VideoCore::Shadow::Stage;
    switch (s) {  // vpgcn::ShaderStage: vertex, pixel, compute, export, geometry, copy shader
    case 1: return Stage::Ps;
    case 2: return Stage::Cs;
    case 4: return Stage::Gs;
    case 5: return Stage::Copy;
    default: return Stage::Vs;  // (the ES is the vertex stage of Vulkan's logical stages)
    }
}

// What vpps4 resolved for the call, into the record. (Programs, counts, index and blend factors are the
// adapter's, filled before the call.)
void shadowResolved(const vpps4::Resolved& r) {
    using namespace VideoCore::Shadow;
    Side* side = shadowSide();
    if (!side) return;
    side->status = r.status == vpps4::Resolved::Status::Drawn     ? Status::Drawn
                   : r.status == vpps4::Resolved::Status::Handled ? Status::Handled
                                                                  : Status::Skipped;
    side->reason = r.reason;
    for (size_t i = 0; i < 8; ++i) {
        const vpps4::ResolvedTarget& t = r.color[i];
        side->color[i] = {t.used, t.address, t.width, t.height, t.pitch, t.format, t.numberType, t.compSwap, t.tileMode,
                          t.sliceStart, t.sliceCount, t.samples, t.hostFormat, t.cleared};
    }
    const vpps4::ResolvedDepth& z = r.depth;
    side->depth = {z.used, z.zAddress, z.stencilAddress, z.width, z.height, z.zFormat, z.stencilFormat, z.tileMode, z.samples,
                   z.hostFormat, z.depthClear, z.stencilClear};
    side->buffers.clear();
    for (const vpps4::ResolvedBuffer& b : r.buffers) side->buffers.push_back({shadowStage(b.stage), b.address, b.size, b.stride, b.write, b.pointer});
    side->textures.clear();
    for (const vpps4::ResolvedTexture& t : r.textures) {
        const vpps4::ImageDesc& i = t.image;
        side->textures.push_back({shadowStage(t.stage), i.address, i.dataFormat, i.numFormat, i.type, i.tilingIndex, i.baseLevel,
                                  i.lastLevel, i.width, i.height, {i.dstSel[0], i.dstSel[1], i.dstSel[2], i.dstSel[3]}, t.storage,
                                  t.found, t.hostFormat, t.hostWidth, t.hostHeight});
    }
    side->samplers.clear();
    for (const vpps4::ResolvedSampler& m : r.samplers)
        side->samplers.push_back({shadowStage(m.stage), m.addressU, m.addressV, m.addressW, m.magFilter, m.minFilter, m.mipFilter,
                                  m.anisotropy, m.compare});
    side->topology = r.topology;
    side->viewportValid = r.viewportValid;
    std::copy(std::begin(r.viewport), std::end(r.viewport), side->viewport);
    side->scissorValid = r.scissorValid;
    std::copy(std::begin(r.scissor), std::end(r.scissor), side->scissor);
    side->stateValid = r.stateValid;
    side->cull = r.cull;
    side->frontClockwise = r.frontClockwise;
    side->depthTest = r.depthTest;
    side->depthWrite = r.depthWrite;
    side->depthFunc = r.depthFunc;
    side->stencilTest = r.stencilTest;
    for (size_t i = 0; i < 8; ++i) side->blend[i].enable = r.blendEnable[i];
}

// ASTRO_SHADOW_PIXELS (video_core/shadow_pixels.h): the second renderer. The shadow's own renderer is on the null backend and
// draws nothing; for the draws of a capture frame this one draws for real, on Metal, one draw at a time from the pixels
// Vulkan had before it (PixelCapture), and its targets are read back. It must never write guest memory, so:
//  - Renderer::setGuestReadOnly: no write back, DMA or ZPASS_DONE, and no draw or dispatch that binds a V# buffer for
//    writing (a dispatch that stores to none runs: it writes the GDS or an image of the GPU, never guest memory);
//  - the memory it is given is a private copy (windows of anonymous memory refreshed from the guest at every draw), so
//    even a shader storing through a raw pointer (FLAT) writes the copy: read-only is not enforced by the renderer for
//    those, the private windows are what make it safe;
//  - no page watches, no mirrors, no presentation: it has no hooks for any of them.
// It is created at the first captured draw and switched off for good (PixelsAvailable) if it cannot start or throws.
// Windows of a PixelEngine are mapped (a Draw outside a capture asks the engine to let them go; without any, the engine
// is not even made).
std::atomic<bool> pixelWindowsHeld{false};

struct PixelEngine {
    static constexpr u64 kPage = 16384, kGrid = 1ull << 20, kWindowBytes = 256ull << 20;
    struct Window {
        u64 base = 0, size = 0;
        void* host = nullptr;
        u64 copiedAt = 0;
    };
    struct Seed {
        u64 address = 0;
        vpps4::SeedRequest::Kind kind = vpps4::SeedRequest::Kind::Color;
        const VideoCore::Shadow::PixelImage* image = nullptr;
        bool used = false;
    };
    vpgpu::metal2::ShaderTable shaders;
    std::unique_ptr<vpgpu::metal2::MetalBackend> backend;
    std::unique_ptr<vpgpu::Device> device;
    std::unique_ptr<vpps4::Renderer> renderer;
    bool failed = false;
    unsigned errorLines = 0;
    std::vector<Window> windows;
    u64 windowBytes = 0;
    std::mutex mutex;                 // draw() and release() come from the threads of the Tee's calls
    std::thread::id captureThread;    // the thread of the draws it was given
    bool stuck = false;               // its GPU did not go idle in time: the windows are never unmapped nor refreshed
    bool copyFailed = false;          // a window could not be copied from guest memory in this draw
    u64 epoch = 0;       // one per draw
    u64 captureId = 0;
    // The draw in progress.
    bool drawing = false;
    std::vector<Seed> seeds;
    std::vector<std::pair<u64, u64>> seeded;  // (address, bytes) given to the renderer: invalidated after the draw
    std::string seedFail;
    std::vector<uint8_t> scratch;
    vpps4::Resolved last;
    bool haveLast = false;

    void log(const std::string& line) {
        if ((line.rfind("gpu.err", 0) == 0 || line.rfind("vpps4.shader error", 0) == 0) && errorLines++ < 50)
            LOG_WARNING(Render_Vulkan, "ASTRO_PIXEL vpk {}", line);
    }

    // The private copy of the guest memory around [address, +size) (see the comment above). False: not offered, as the
    // shadow's own region hook does not offer what the host has page-protected.
    bool region(u64 address, u64 size, vpps4::GuestRegion& out) {
        if (!drawing || address < 0x10000) return false;
        const u64 from = address & ~(kWindow - 1);
        const u64 to = std::max(from + kWindow, (address + size + kWindow - 1) & ~(kWindow - 1));
        u64 begin, end;
        void* mirror = nullptr;
        if (!cachedSpan(address, from, to, begin, end, mirror) || address + size > end || mirror) return false;
        if (begin % kPage || end % kPage) return false;
        const u64 lo = std::max(begin, address & ~(kGrid - 1));
        const u64 hi = std::min(end, std::max(lo + kGrid, (address + size + kGrid - 1) & ~(kGrid - 1)));
        Window* w = nullptr;
        for (Window& x : windows)
            if (x.base == lo && x.size == hi - lo) w = &x;
        if (!w) {
            if (windowBytes + (hi - lo) > kWindowBytes) return false;
            void* host = ::mmap(nullptr, hi - lo, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
            if (host == MAP_FAILED || reinterpret_cast<uintptr_t>(host) % kPage) return false;
            windowBytes += hi - lo;
            windows.push_back({lo, hi - lo, host, 0});
            w = &windows.back();
            pixelWindowsHeld.store(true, std::memory_order_relaxed);
        }
        if (w->copiedAt != epoch) {
            // Not a memcpy: a page the host protects (Vulkan's PageManager, which the shadow has no probe for) would
            // fault in the middle of the draw; the kernel's copy answers with an error instead, touching nothing.
            vm_size_t copied = 0;
            if (vm_read_overwrite(mach_task_self(), vm_address_t(lo), vm_size_t(hi - lo), vm_address_t(w->host), &copied) != KERN_SUCCESS ||
                copied != hi - lo) {
                copyFailed = true;
                return false;
            }
            w->copiedAt = epoch;
        }
        out = {w->base, w->size, w->host, false};
        return true;
    }

    // Hooks::seed: the texels Vulkan had for the surface, if the draw has them and they are the same layout.
    bool seed(const vpps4::SeedRequest& q, vpps4::SeedImage& out) {
        using VideoCore::Shadow::ParsePixelFormat;
        for (Seed& s : seeds) {
            if (s.used || s.address != q.address) continue;
            if (s.kind != q.kind && s.kind != vpps4::SeedRequest::Kind::Texture) continue;
            const auto vpkFormat = ParsePixelFormat(vpgpu::formatInfo(q.format).name);
            const auto vkFormat = ParsePixelFormat(s.image->format);
            if (!vpkFormat || !vkFormat || !VideoCore::Shadow::SameLayout(*vkFormat, *vpkFormat)) {
                seedFail = std::string("format ") + s.image->format + " / " + vpgpu::formatInfo(q.format).name;
                return false;
            }
            if (q.width != s.image->surfaceWidth || q.height != s.image->surfaceHeight) {
                seedFail = "size";
                return false;
            }
            const bool whole = s.image->width == s.image->surfaceWidth && s.image->height == s.image->surfaceHeight;
            if (whole) {
                out.data = s.image->texels.data();
            } else {
                scratch = VideoCore::Shadow::ExpandRect(*s.image, vkFormat->bytes);
                out.data = scratch.data();
            }
            out.rowBytes = 0;
            s.used = true;
            seeded.push_back({q.address, u64(q.width) * q.height * vkFormat->bytes});
            return true;
        }
        return false;
    }

    // The capture is over for `thread` (it drew outside one): the windows go back to the system. The renderer lets go of
    // what it made over them first (invalidate, abandonOwners, dropGuestBuffers: no buffer stays alive over unmapped
    // pages, nor is reused for a later map at the same address) and the GPU must be idle; if it is not (it is waited for,
    // bounded), the windows stay mapped for good and the engine is off.
    void release(std::thread::id thread) {
        std::scoped_lock lock{mutex};
        if (thread != captureThread || !pixelWindowsHeld.load(std::memory_order_relaxed) || stuck) return;
        bool idle = true;
        if (renderer) {
            renderer->submit();
            idle = device->waitIdle(5'000'000'000ull);
            if (idle) {
                renderer->abandonOwners(0, 1ull << 47);
                renderer->invalidate(0, 1ull << 47);
                idle = renderer->dropGuestBuffers();
            }
        }
        if (!idle) {
            stuck = true;
            VideoCore::Shadow::PixelsAvailable().store(false, std::memory_order_relaxed);
            LOG_WARNING(Render_Vulkan, "ASTRO_PIXEL disabled reason=the second renderer's GPU did not go idle: its windows stay mapped");
            return;
        }
        for (Window& w : windows) ::munmap(w.host, w.size);
        windows.clear();
        windowBytes = 0;
        pixelWindowsHeld.store(false, std::memory_order_relaxed);
    }

    bool start() {
        if (renderer) return true;
        if (failed) return false;
        failed = true;  // (until it is up)
        vpgpu::metal2::MetalOptions options;
        options.framesInFlight = 2;
        backend = std::make_unique<vpgpu::metal2::MetalBackend>(shaders, [this](const std::string& l) { log(l); }, options);
        if (!backend->ok()) return false;
        device = std::make_unique<vpgpu::Device>(*backend, 2, [this](const std::string& l) { log(l); });
        device->setRefuseFailedBuffers(true);
        vpps4::Hooks hooks;
        hooks.region = [this](u64 a, u64 n, vpps4::GuestRegion& g) { return region(a, n, g); };
        hooks.shader = [this](u64 id, vpir::Stage, const vpmsl::MslShader& m) { shaders.add(id, toMetal(m)); };
        hooks.log = [this](const std::string& l) { log(l); };
        hooks.resolved = [this](const vpps4::Resolved& r) { last = r, haveLast = true; };
        hooks.seed = [this](const vpps4::SeedRequest& q, vpps4::SeedImage& i) { return seed(q, i); };
        renderer = std::make_unique<vpps4::Renderer>(*device, std::move(hooks));
        renderer->setMaxSamples(1);
        renderer->setGuestReadOnly(true);
        failed = false;
        LOG_INFO(Render_Vulkan, "ASTRO_PIXEL second renderer on (Metal, private copy of guest memory, guest read-only)");
        return true;
    }

    // Draws `clear` (when the metadata asked for a clear) and `d` from the pixels in `pc`, and reads the colour targets.
    void draw(VideoCore::Shadow::PixelCapture& pc, const vpps4::DrawState* clear, const vpps4::DrawState& d) {
        using namespace VideoCore::Shadow;
        std::scoped_lock lock{mutex};
        if (stuck) {
            pc.vpkSkip = "gpu timeout";
            return;
        }
        if (!start()) {
            PixelsAvailable().store(false, std::memory_order_relaxed);
            pc.vpkSkip = "second renderer unavailable";
            LOG_WARNING(Render_Vulkan, "ASTRO_PIXEL disabled reason=the second renderer could not start");
            return;
        }
        if (pc.captureId != captureId) {  // a new capture: nothing it held is trusted
            captureId = pc.captureId;
            renderer->abandonOwners(0, 1ull << 47);
            renderer->invalidate(0, 1ull << 47);
        }
        captureThread = std::this_thread::get_id();
        // (a pipeline new to this renderer is made within the draw, not left for a later frame: for what is left of the
        // capture's budget, at most 100 ms; the GPU is idle here, every draw waited for it)
        device->setHoldMs(pc.holdMs);
        ++epoch;
        seeds.clear();
        seeded.clear();
        seedFail.clear();
        copyFailed = false;
        haveLast = false;
        for (unsigned i = 0; i < 8; ++i)
            if (pc.color[i].used) seeds.push_back({pc.color[i].address, vpps4::SeedRequest::Kind::Color, &pc.color[i].pre, false});
        if (pc.depth.used) seeds.push_back({pc.depth.address, vpps4::SeedRequest::Kind::Depth, &pc.depth.pre, false});
        for (const PixelTexture& t : pc.textures) seeds.push_back({t.address, vpps4::SeedRequest::Kind::Texture, t.image.get(), false});
        drawing = true;
        std::string clearFail;
        std::vector<vpgpu::TextureId> targets(8);
        bool drawn = false, idle = false;
        vpps4::CpuTimes times;
        try {
            if (clear) {
                renderer->draw(*clear);
                if (!haveLast || last.status == vpps4::Resolved::Status::Skipped)  // (a clear is "handled": it waits for the next pass)
                    clearFail = haveLast ? last.reason : "no answer";
            }
            haveLast = false;
            renderer->draw(d);
            drawn = haveLast && last.status == vpps4::Resolved::Status::Drawn;
            if (drawn)
                for (unsigned i = 0; i < 8; ++i)
                    if (pc.color[i].used) targets[i] = renderer->colorTargetAt(pc.color[i].address);  // (kept: its pass stores it)
            renderer->submit();
            idle = device->waitIdle(5'000'000'000ull);
            times = renderer->takeCpuTimes();
        } catch (...) {
            // (the GPU may be reading the windows: not idle, they are neither refreshed nor unmapped)
            drawing = false;
            try {
                renderer->submit();
                stuck = !device->waitIdle(5'000'000'000ull);
            } catch (...) {
                stuck = true;
            }
            throw;
        }
        drawing = false;
        if (!idle) {
            stuck = true;
            PixelsAvailable().store(false, std::memory_order_relaxed);
            LOG_WARNING(Render_Vulkan, "ASTRO_PIXEL disabled reason=the second renderer's GPU did not finish in 5 s");
            pc.vpkSkip = "gpu timeout";
            return;
        }
        for (const auto& [address, bytes] : seeded) renderer->invalidate(address, bytes);  // (the next draw is seeded again, or reads memory)
        const bool unusedSeed = std::any_of(seeds.begin(), seeds.end(), [](const Seed& x) { return !x.used; });
        if (!haveLast) {
            pc.vpkSkip = "no answer";
        } else if (!clearFail.empty()) {
            pc.vpkSkip = "clear draw: " + clearFail;
        } else if (copyFailed) {
            pc.vpkSkip = "guest memory protected";
        } else if (last.status != vpps4::Resolved::Status::Drawn) {
            pc.vpkSkip = (last.status == vpps4::Resolved::Status::Skipped ? "skipped: " : "handled: ") + last.reason;
        } else if (!seedFail.empty()) {
            pc.vpkSkip = "seed " + seedFail;
        } else if (unusedSeed) {
            pc.vpkSkip = "seed not consumed";  // (the renderer drew from guest memory what Vulkan had in an image)
        } else if (times.holdTimeouts != 0) {
            pc.vpkSkip = "pipeline compiling";
        } else {
            readTargets(pc, targets);
        }
    }

    void readTargets(VideoCore::Shadow::PixelCapture& pc, const std::vector<vpgpu::TextureId>& targets) {
        using namespace VideoCore::Shadow;
        for (unsigned i = 0; i < 8 && pc.vpkSkip.empty(); ++i) {
            PixelTarget& t = pc.color[i];
            if (!t.used) continue;
            const vpps4::ResolvedTarget& rt = last.color[i];
            const auto format = ParsePixelFormat(rt.hostFormat);
            if (!rt.used || !targets[i] || !format) {
                pc.vpkSkip = "no target " + std::to_string(i);
                break;
            }
            if (rt.width != t.post.surfaceWidth || rt.height != t.post.surfaceHeight) {
                pc.vpkSkip = "target size";
                break;
            }
            vpgpu::TextureSpan span;
            span.texture = targets[i];
            span.width = rt.width;
            span.height = rt.height;
            std::vector<uint8_t> bytes;
            if (backend->readTexture(span, bytes) != vpgpu::ReadResult::Ok ||
                bytes.size() != size_t(rt.width) * rt.height * format->bytes) {
                pc.vpkSkip = "readback";
                break;
            }
            t.vpkPost = t.post;
            t.vpkPost.format = rt.hostFormat;
            t.vpkPost.texels = CropRect(bytes.data(), rt.width, format->bytes, {t.post.x, t.post.y, t.post.width, t.post.height});
        }
    }
};

PixelEngine& pixelEngine() {
    static PixelEngine& p = *new PixelEngine;  // never destroyed, like the engine
    return p;
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
    c.sliceCount = ViewSliceCount(cb.BaseSlice(), cb.view.slice_max);
    c.samples = uint8_t(cb.NumSamples());  // colour fragments (EQAA: what the surface stores)
    c.coverage = uint8_t(1u << cb.attrib.num_samples_log2);
    c.fastClear = cb.info.fast_clear;
    c.clearWord = {cb.clear_word0, cb.clear_word1};
    return c;
}

// The colour target at the size the title set it up with (SetRenderTarget's extent), not the tile-aligned pitch and height:
// sizes, viewports and later reads of the target agree with the title's. Draws and resolves both go through here, or the
// engine finds no target of the resolve's size at the address. Under the engine lock (`extents`).
vpps4::ColorTarget sizedColorTarget(Engine& e, const AmdGpu::Regs& regs, const AmdGpu::CbDbExtent& ext, unsigned i,
                                    VpkengineRenderer::TargetExtents::Source* how = nullptr) {
    vpps4::ColorTarget c = colorTarget(regs, i);
    const auto source = e.extents.Apply(c.address, c.format, ext.Valid(), ext.width, ext.height, c.width, c.height);
    if (how) *how = source;
    return c;
}

// Whether the clear words of a target decode to the colour it clears to (fastClearColor; not for every format).
bool fastClearDecodes(const vpps4::ColorTarget& c) {
    bool exact = true;
    vpps4::fastClearColor(c.format, c.numberType, c.compSwap, c.clearWord, exact);
    return exact;
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

// Probe: draws left out before the renderer, by reason (cumulative; the reasons are literals, so there are few).
void publishLeftOut() {
    u64 all = 0;
    const size_t n = gLeftOutUsed.load(std::memory_order_acquire);
    for (size_t i = 0; i < n; ++i) {
        const char* why = gLeftOut[i].why.load(std::memory_order_acquire);
        if (!why) continue;
        const u64 total = gLeftOut[i].total.load(std::memory_order_relaxed);
        all += total;
        pm::counter("LEFTOUT", "leftout_" + pm::Registry::sanitize(why)).set(total);
    }
    pm::counter("LEFTOUT", "leftout_total").set(all);
}

// Probe: the process as the system counts it (PROC family): footprint and its parts, the malloc heap, the code arena
// (FEX), the console's memory, threads and CPU time. The region walk by kind is the watchdog's MEMORY line (guest_watchdog.cpp).
void publishProcess() {
    const double mb = 1.0 / 1048576.0;
    const auto G = [](const char* name, double v) { pm::gauge("PROC", name).set(v); };
    task_vm_info_data_t vm{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&vm), &count) == KERN_SUCCESS) {
        G("phys_footprint_mb", double(vm.phys_footprint) * mb), G("resident_mb", double(vm.resident_size) * mb);
        G("internal_mb", double(vm.internal) * mb), G("compressed_mb", double(vm.compressed) * mb);
        G("external_mb", double(vm.external) * mb), G("virtual_mb", double(vm.virtual_size) * mb);
        G("purgeable_volatile_mb", double(vm.purgeable_volatile_pmap) * mb);
        if (u64(count) * sizeof(natural_t) >= offsetof(task_vm_info_data_t, ledger_tag_graphics_footprint_compressed) +
                                                  sizeof(vm.ledger_tag_graphics_footprint_compressed)) {
            G("graphics_mb", double(vm.ledger_tag_graphics_footprint) * mb);
            G("graphics_compressed_mb", double(vm.ledger_tag_graphics_footprint_compressed) * mb);
            G("purgeable_nonvolatile_mb", double(vm.ledger_purgeable_nonvolatile) * mb);
        }
        if (u64(count) * sizeof(natural_t) >= offsetof(task_vm_info_data_t, ledger_phys_footprint_peak) + sizeof(vm.ledger_phys_footprint_peak))
            G("phys_footprint_peak_mb", double(vm.ledger_phys_footprint_peak) * mb);
    }
    G("available_mb", double(os_proc_available_memory()) * mb);
    malloc_statistics_t heap{};
    malloc_zone_statistics(nullptr, &heap);
    G("malloc_in_use_mb", double(heap.size_in_use) * mb), G("malloc_allocated_mb", double(heap.size_allocated) * mb);
    G("malloc_blocks", double(heap.blocks_in_use));
    const auto arena = Common::JitArena::GetUsage();
    G("jit_arena_used_mb", double(arena.used) * mb), G("jit_arena_most_mb", double(arena.most) * mb);
    G("jit_arena_size_mb", double(arena.size) * mb);
    G("console_resident_mb", double(Core::ResidentConsoleMemory()) * mb);
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t threadCount = 0;
    if (task_threads(mach_task_self(), &threads, &threadCount) == KERN_SUCCESS) {
        G("threads", double(threadCount));
        for (mach_msg_type_number_t i = 0; i < threadCount; ++i) mach_port_deallocate(mach_task_self(), threads[i]);
        vm_deallocate(mach_task_self(), reinterpret_cast<vm_address_t>(threads), threadCount * sizeof(thread_act_t));
    }
    // CPU time of the process (live threads plus the ones that ended), cumulative: the interval's delta over its length is the CPU use.
    u64 us = 0;
    mach_task_basic_info_data_t basic{};
    mach_msg_type_number_t basicCount = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, reinterpret_cast<task_info_t>(&basic), &basicCount) == KERN_SUCCESS)
        us += u64(basic.user_time.seconds + basic.system_time.seconds) * 1000000 + u64(basic.user_time.microseconds + basic.system_time.microseconds);
    task_thread_times_info_data_t live{};
    mach_msg_type_number_t liveCount = TASK_THREAD_TIMES_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_THREAD_TIMES_INFO, reinterpret_cast<task_info_t>(&live), &liveCount) == KERN_SUCCESS)
        us += u64(live.user_time.seconds + live.system_time.seconds) * 1000000 + u64(live.user_time.microseconds + live.system_time.microseconds);
    pm::counter("PROC", "cpu_ms").set(us / 1000);
}

// Probe: size of the persistent caches on disk (the Metal pipeline archives, .metalar, and the rest), walked every ~30 s.
void publishDisk(const std::filesystem::path& cacheDir) {
    if (cacheDir.empty()) return;
    u64 metalar = 0, metalarBytes = 0, others = 0, otherBytes = 0;
    std::error_code ec;
    for (std::filesystem::recursive_directory_iterator it(cacheDir, std::filesystem::directory_options::skip_permission_denied, ec), end;
         !ec && it != end; it.increment(ec)) {
        std::error_code fe;
        if (!it->is_regular_file(fe) || fe) continue;
        const u64 size = it->file_size(fe);
        if (fe) continue;
        if (it->path().extension() == ".metalar") ++metalar, metalarBytes += size;
        else ++others, otherBytes += size;
    }
    pm::gauge("PSO", "metalar_files").set(double(metalar)), pm::gauge("PSO", "metalar_mb").set(double(metalarBytes) / 1048576.0);
    pm::gauge("PSO", "cache_other_files").set(double(others)), pm::gauge("PSO", "cache_other_mb").set(double(otherBytes) / 1048576.0);
}

void leftOut(const char* why) {
    if (VideoCore::Shadow::Side* side = shadowSide()) {
        side->status = VideoCore::Shadow::Status::Skipped;
        side->reason = why;
    }
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
                           u32(cb.Height()), u32(cb.Pitch()), u32(cb.BaseSlice()), ViewSliceCount(cb.BaseSlice(), cb.view.slice_max),
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
    // Shadow (Mode::Shadow): protects nothing, writes nothing. Everything below that reaches the page manager
    // (watches, owned ranges, write backs) is then empty and never runs, so `page_manager` is not dereferenced.
    const bool shadow;
    // Null in the shadow: a PageManager keeps one static rasterizer pointer and one fault handler, the Vulkan renderer's.
    std::unique_ptr<VideoCore::PageManager> page_manager;
    // Guest memory the title mapped for the GPU (MapMemory/UnmapMemory).
    pm::TimedMutex<std::mutex> mapped_mutex{"mapped"};
    std::map<VAddr, VAddr> mapped;  // start -> end
    // Ranges textures were filled from, watched for CPU writes (start -> size).
    pm::TimedMutex<std::mutex> watch_mutex{"watch"};
    std::map<VAddr, u64> watched;
    // Whether [a, b) overlaps a range this rasterizer protects (texture sources, memory an image is ahead of).
    bool anyWatchIn(VAddr a, VAddr b) {
        static pm::Timer& timer = pm::timer("TIME", "any_watch_in");
        const pm::ScopedSampled scope(timer);  // (hot: calls exact, time estimated from 1 in 16)
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
    // Probe: the sizes of the tables above (APP family). Takes each lock for the time of a size() call.
    void publishTables() {
        {
            std::scoped_lock l{mapped_mutex};
            pm::gauge("APP", "mapped_ranges").set(double(mapped.size()));
            u64 bytes = 0;
            for (const auto& [start, end] : mapped) bytes += end - start;
            pm::gauge("APP", "mapped_mb").set(double(bytes) / 1048576.0);
        }
        {
            std::scoped_lock l{watch_mutex};
            pm::gauge("APP", "watched_ranges").set(double(watched.size()));
            u64 bytes = 0;
            for (const auto& [start, size] : watched) bytes += size;
            pm::gauge("APP", "watched_mb").set(double(bytes) / 1048576.0);
        }
        {
            std::scoped_lock l{owned_mutex};
            u64 bytes = 0;
            for (const auto& [range, count] : owned) bytes += range.second;
            pm::gauge("APP", "owned_ranges").set(double(owned.size()));
            pm::gauge("APP", "owned_mb").set(double(bytes) / 1048576.0);
            pm::gauge("APP", "ahead_since").set(double(aheadSince.size()));
        }
    }
    // Ranges let go of lately (watch_mutex): a second thread faulting on the same page finds the watch
    // gone already, and its access counts as handled if the page can be written now. Kept for a short
    // time only (like releasedOwned), so an access that faults for another reason is not retried for ever.
    VideoCore::RecentRanges<64> released;
    bool recentlyReleased(VAddr a, u64 n) {
        return released.Overlaps(a, n, std::chrono::steady_clock::now(), std::chrono::milliseconds(200));
    }

    Impl(Rasterizer* self, AmdGpu::Liverpool* lp, bool shadow_)
        : liverpool{lp}, shadow{shadow_}, page_manager{shadow_ ? std::unique_ptr<VideoCore::PageManager>{} : std::make_unique<VideoCore::PageManager>(self)} {}

    bool isMapped(VAddr addr, u64 size) {
        if (size == 0 || addr > ~u64(0) - size) return false;
        std::scoped_lock l{mapped_mutex};
        auto it = mapped.upper_bound(addr);
        if (it == mapped.begin()) return false;
        --it;
        return addr >= it->first && addr + size <= it->second;
    }

    // Whether any of [addr, addr + size) is mapped.
    bool anyMapped(VAddr addr, u64 size) {
        std::scoped_lock l{mapped_mutex};
        auto it = mapped.upper_bound(addr);
        if (it != mapped.begin() && std::prev(it)->second > addr) return true;
        return it != mapped.end() && it->first < addr + size;
    }

    void watch(VAddr a, u64 n) {
        if (!isMapped(a, n)) return;
        // (entry and protection change together under watch_mutex, the order invalidate takes the locks in:
        // it cannot release an entry whose page is not protected yet, nor leave a watcher without an entry)
        std::scoped_lock l{watch_mutex};
        auto [it, inserted] = watched.try_emplace(a, n);
        if (!inserted) {
            if (it->second == n) return;  // already watched
            page_manager->UpdatePageWatchers<false>(a, it->second);
            it->second = n;
        }
        page_manager->UpdatePageWatchers<true>(a, n);
    }

    // CPU wrote [a, a + n): textures read from there are refilled, their watches dropped (the
    // pages are written freely until a texture is filled from them again).
    bool invalidate(VAddr a, u64 n) {
        bool any = false;
        // (a second round if the page is still protected: a watch added after the first one, by a texture filled
        // from the same page, is released too, the CPU is writing there)
        for (int round = 0; round < 2; ++round) {
            {
                std::scoped_lock l{watch_mutex};
                // (a texture starts at most 1 GiB below what it spans)
                auto it = watched.lower_bound(a > (1ull << 30) ? a - (1ull << 30) : 0);
                while (it != watched.end() && it->first < a + n) {
                    if (it->first + it->second > a) {
                        any = true;
                        released.Note(it->first, it->second, std::chrono::steady_clock::now());
                        // (unprotected before watch_mutex is let go: a second thread that finds the range
                        // in `released` finds the page open, not still being opened by this one)
                        page_manager->UpdatePageWatchers<false>(it->first, it->second);
                        engine().queueInvalidate(it->first, it->second);
                        it = watched.erase(it);
                    } else {
                        ++it;
                    }
                }
                if (!any && !recentlyReleased(a, n)) return false;
            }
            // (handled only if the pages are writable now; else the fault is left to show itself)
            if (!page_manager->IsWriteProtected(a, n)) return true;
        }
        return any;
    }

    // ---- Memory an image on the GPU is ahead of --------------------------------------------------
    // Ranges whose newest bytes live in a GPU image (render target, depth buffer, storage image):
    // the pages are inaccessible to the CPU (a write watcher plus a read watcher) until the renderer
    // has written the image back (re-tiled it into the guest memory). The first access faults here.
    // Keyed by (start, size) with a count: two images may share a range.
    pm::TimedMutex<std::mutex> owned_mutex{"owned"};
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
    bool recentlyReleasedOwned(VAddr addr, u64 n) {
        std::scoped_lock l{owned_mutex};
        const auto now = std::chrono::steady_clock::now();
        for (const auto& r : releasedOwned)
            if (r.size && r.start < addr + n && r.start + r.size > addr && now - r.at < std::chrono::milliseconds(200)) return true;
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
            page_manager->UpdatePageWatchers<true>(a, n);
            page_manager->UpdateReadWatchers<true>(a, n);
        } else {
            auto it = owned.find({a, n});
            if (it == owned.end()) return;
            if (--it->second != 0) return;
            owned.erase(it);
            noteReleasedOwned(a, n);
            page_manager->UpdateReadWatchers<false>(a, n);
            page_manager->UpdatePageWatchers<false>(a, n);
        }
    }

    // The owned ranges that overlap [addr, addr + n).
    std::vector<std::pair<VAddr, u64>> ownedIn(VAddr addr, u64 n) {
        std::vector<std::pair<VAddr, u64>> hit;
        std::scoped_lock l{owned_mutex};
        auto it = owned.lower_bound({addr > (1ull << 30) ? addr - (1ull << 30) : 0, 0});
        for (; it != owned.end() && it->first.first < addr + n; ++it)
            if (addr < it->first.first + it->first.second) hit.push_back(it->first);
        return hit;
    }

    // Takes every watch off the owned ranges that overlap [a, a + n) (they are being unmapped).
    void dropOwned(VAddr a, u64 n) {
        std::scoped_lock l{owned_mutex};
        for (auto it = owned.begin(); it != owned.end();) {
            if (it->first.first < a + n && it->first.first + it->first.second > a) {
                // (setOwned adds the watchers once per key, whatever the count: released once)
                page_manager->UpdateReadWatchers<false>(it->first.first, it->first.second);
                page_manager->UpdatePageWatchers<false>(it->first.first, it->first.second);
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
    // True if the access belonged to an owned range (the access is retried). The access is the
    // bytes [addr, addr + n).
    bool resolveOwned(VAddr addr, u64 n, bool write);
};

Rasterizer::Rasterizer(AmdGpu::Liverpool* liverpool, Mode mode)
    : impl{std::make_unique<Impl>(this, liverpool, mode == Mode::Shadow)} {
    // (the shadow does not bind itself: the Tee does, to both renderers)
    if (!impl->shadow) liverpool->BindRasterizer(this);
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (impl->shadow) {
        // No page watches, no protected host pages, no mirrors: the renderer finds the CPU's writes by content,
        // and the Tee tells it of the memory manager's (Invalidate, Map, Unmap).
        e.shadow = true;
        gShadowEngine.store(true, std::memory_order_release);
        e.start();
        return;
    }
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
    gProbeTables.store([](void* ctx) { static_cast<Impl*>(ctx)->publishTables(); }, std::memory_order_release);
    e.start();
}

bool Rasterizer::Failed() const {
    return engine().failed;
}

void ShadowEndFrame() {
    if (gShadowEngine.load(std::memory_order_acquire)) {
        gShadowFlip.store(true, std::memory_order_release);
        VideoCore::Shadow::Frames().fetch_add(1, std::memory_order_relaxed);  // (the Tee's comparison writes its summary by these)
    }
}

Rasterizer::~Rasterizer() {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    e.watchWrites = nullptr;
    e.watchOwned = nullptr;
    if (e.renderer) e.renderer->flushReports();
    flushLeftOut();
    gProbeTables.store(nullptr, std::memory_order_release);
    gWatchProbe.store(nullptr, std::memory_order_release);
    gWatchProbeContext.store(nullptr, std::memory_order_release);
    if (pm::enabled()) {  // the run's peaks and means
        for (const std::string& line : pm::registry().summary()) LOG_INFO(Render_Vulkan, "{}", line);
    }
}

void Rasterizer::Draw(bool is_indexed, u32 index_offset) {
    shadowBegin("left before the renderer (no draw to make, or not reached)");
    Engine::Timer timer{engine().adapterNs};
    engine().adapterCalls.fetch_add(1, std::memory_order_relaxed);
    const auto& regs = impl->liverpool->regs;
    using Mode = AmdGpu::ColorControl::OperationMode;
    switch (regs.color_control.mode) {
    // No-op by design: the host keeps no FMASK compression (an FMask read is the identity map).
    case Mode::FmaskDecompress: return;
    // The host keeps no CMASK either: eliminating the fast clear is the clear itself, done below with the targets
    // (when the title cleared the metadata and no draw has used the target since).
    case Mode::EliminateFastClear: break;
    case Mode::Resolve: {
        if (!regs.color_buffers[0] || !regs.color_buffers[1]) return;
        Engine& e = engine();
        std::scoped_lock g{e.lock};
        if (!e.start()) return;
        e.applyPending();
        const auto& ext = impl->liverpool->last_cb_extent;
        VpkengineRenderer::TargetExtents::Source how0{}, how1{};
        const vpps4::ColorTarget src = sizedColorTarget(e, regs, ext[0], 0, &how0);
        const vpps4::ColorTarget dst = sizedColorTarget(e, regs, ext[1], 1, &how1);
        // P1: what the resolve is told (hint = the title's extent, cache = the one last drawn at the address, none = the CB's
        // pitch and height); first 40 resolves, then one in 600.
        static std::atomic<u64> p1{0};
        if (const u64 n = p1++; n < 40 || n % 600 == 0) {
            static constexpr const char* names[] = {"none", "hint", "cache"};
            const auto& cb0 = regs.color_buffers[0];
            const auto& cb1 = regs.color_buffers[1];
            LOG_INFO(Render_Vulkan,
                     "VPKENGINE_PROBE P1 resolve n={} ext0={}/{}x{} ext1={}/{}x{} src {:#x} {}x{} (pitch {} height {}) via {} dst {:#x} {}x{} (pitch {} height {}) via {}",
                     n, ext[0].Valid(), u32(ext[0].width), u32(ext[0].height), ext[1].Valid(), u32(ext[1].width), u32(ext[1].height),
                     src.address, src.width, src.height, cb0.Pitch(), cb0.Height(), names[int(how0)], dst.address, dst.width,
                     dst.height, cb1.Pitch(), cb1.Height(), names[int(how1)]);
        }
        e.renderer->resolve(src, dst);
        if (e.probeArmed && e.resolves.size() < 16) e.resolves.push_back({dst.address, dst.width, dst.height, dst.pitch});
        e.noteWork();
        return;
    }
    default: break;
    }
    const bool eliminate = regs.color_control.mode == Mode::EliminateFastClear;
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
    // A draw of a capture frame (ASTRO_SHADOW_PIXELS) that Vulkan read back: it is also drawn for real below.
    VideoCore::Shadow::Record* shadowRecord = VideoCore::Shadow::Current();
    VideoCore::Shadow::PixelCapture* pixels =
        shadowRecord != nullptr && shadowRecord->pixels && shadowRecord->pixels->vkSkip.empty() ? shadowRecord->pixels.get() : nullptr;
    // (a draw outside a capture, of the thread that drew the captured ones: the windows of the one that is over go back;
    // nothing is made when the pixel comparison is off, and the draws of other threads leave the capture alone)
    if ((shadowRecord == nullptr || !shadowRecord->pixels) && pixelWindowsHeld.load(std::memory_order_relaxed))
        pixelEngine().release(std::this_thread::get_id());
    std::optional<vpps4::DrawState> pixelClear;

    // Targets. The ones a title cleared by writing their fast clear metadata (see Engine::metas) are cleared
    // before this draw, as the Vulkan backend does with the load action of the pass.
    std::array<bool, 8> clearColor{};
    bool clearDepth = false;
    if (regs.color_control.mode != Mode::Disable)
        for (unsigned i = 0; i < 8; ++i) {
            const auto& cb = regs.color_buffers[i];
            if (!cb) continue;
            vpps4::ColorTarget& c = d.color[i];
            c = sizedColorTarget(e, regs, impl->liverpool->last_cb_extent[i], i);
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
            if (pm::enabled()) {
                e.probeCmaskDraws += cb.info.fast_clear && cb.CmaskAddress();
                e.probeCmaskUndecodable += cb.info.fast_clear && cb.CmaskAddress() && !fastClearDecodes(c);
                e.probeFmaskDraws += cb.info.compression && cb.FmaskAddress();
            }
            if (cb.info.fast_clear && cb.CmaskAddress()) e.metas.Register(VideoCore::SurfaceMetas::Type::CMask, cb.CmaskAddress());
            if (cb.info.compression && cb.FmaskAddress()) e.metas.Register(VideoCore::SurfaceMetas::Type::FMask, cb.FmaskAddress());
            // (a clear colour that cannot be decoded is not applied, and the metadata is left alone: the target is
            // drawn as it was before the host tracked fast clears, not cleared to a colour that is not the title's)
            if (!eliminate && fastClearDecodes(c)) {
                clearColor[i] = e.metas.IsCleared(cb.CmaskAddress(), cb.BaseSlice());
                e.metas.Touch(cb.CmaskAddress(), cb.BaseSlice(), false);
            }
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
        d.depth.sliceCount = ViewSliceCount(regs.depth_view.slice_start, regs.depth_view.slice_max);
        d.depth.samples = uint8_t(db.NumSamples());
        d.depth.depthClear = regs.depth_render_control.depth_clear_enable;
        d.depth.stencilClear = regs.depth_render_control.stencil_clear_enable;
        d.depth.clearDepth = regs.depth_clear;
        d.depth.clearStencil = uint8_t(regs.stencil_clear);
        d.depth.pitch = db.Pitch();  // (the allocation: guest memory is laid out at it when the hint below is smaller)
        d.depth.rows = db.Height();
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
        if (!eliminate) {
            const VAddr htile = regs.depth_htile_data_base.GetAddress();
            const u32 slice = regs.depth_view.slice_start;
            if (db.z_info.tile_surface_enable && htile) e.metas.Register(VideoCore::SurfaceMetas::Type::HTile, htile);
            if (db.z_info.tile_surface_enable && htile && db.DepthValid()) e.htileDepths[htile] = {db.DepthAddress(), regs.depth_clear};
            if (pm::enabled()) e.probeHtileDraws += db.z_info.tile_surface_enable && htile;
            clearDepth = db.DepthValid() && !d.depth.depthClear && e.metas.IsCleared(htile, slice);
            e.metas.Touch(htile, slice, false);
        }
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

    // The clears the metadata asks for, as a RectList draw of the same targets (vpps4 turns it into the load action
    // of the next pass into them): a fast clear to the target's clear words, a depth clear to DB_DEPTH_CLEAR (the
    // depth plane only). An FCE pass clears colour target 0 alone, every slice, and draws nothing else.
    if (eliminate) {
        const auto& cb = regs.color_buffers[0];
        clearColor = {};
        if (cb && cb.info.fast_clear && fastClearDecodes(d.color[0]) && e.metas.IsCleared(cb.CmaskAddress(), cb.view.slice_start)) {
            for (u32 slice = cb.view.slice_start; slice <= cb.view.slice_max; ++slice)
                e.metas.Touch(cb.CmaskAddress(), slice, false);
            clearColor[0] = true;
            ++e.metaEliminates;
        }
    }
    if (clearDepth || std::any_of(clearColor.begin(), clearColor.end(), [](bool b) { return b; })) {
        vpps4::DrawState clear = d;
        clear.primitive = vpps4::PrimitiveType::RectList;
        clear.count = 3;
        clear.instances = 1;
        for (unsigned i = 0; i < 8; ++i) {
            clear.color[i].fastClear = clearColor[i];
            if (clearColor[i]) clear.color[i].writeMask = 0xF;  // (an FCE shader exports nothing: its mask may be empty)
            e.metaColorClears += clearColor[i];
        }
        clear.depth.depthClear = clearDepth;
        clear.depth.stencilClear = false;
        clear.depth.depthCopy = false;
        e.metaDepthClears += clearDepth;
        ++e.metaClearDraws;
        e.renderer->draw(clear);
        if (pixels) pixelClear = clear;
    }
    if (eliminate) {
        e.noteWork();
        return;
    }

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
            const u64 generation = spanCache().generation();
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
                        body.generation = generation;  // (read before readable(): a later change of the map leaves it stale)
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
    if (VideoCore::Shadow::Side* side = shadowSide()) {
        // (the programs are the GCN binaries' own hashes, the same numbers Vulkan names its shaders by)
        side->hash[size_t(VideoCore::Shadow::Stage::Vs)] = AmdGpu::GetParams(geometry ? regs.es_program : regs.vs_program).hash;
        if (geometry) side->hash[size_t(VideoCore::Shadow::Stage::Gs)] = AmdGpu::GetParams(regs.gs_program).hash;
        if (regs.ps_program.Address<VAddr>() != 0) side->hash[size_t(VideoCore::Shadow::Stage::Ps)] = AmdGpu::GetParams(regs.ps_program).hash;
        side->count = d.count;
        side->instances = d.instances;
        side->index32 = d.index32;
        side->indexAddress = d.indexAddress;
        if (d.indexAddress && !d.indirectAddress) {
            const u64 bytes = u64(d.count) * (d.index32 ? 4 : 2);
            side->indexBytes = std::min(bytes, readable(d.indexAddress, bytes));
        }
        for (unsigned i = 0; i < 8; ++i) {
            const vpps4::Blend& b = d.blend[i];
            side->blend[i] = {b.enable, b.colorSrc, b.colorDst, b.colorFunc,
                              b.separateAlpha ? b.alphaSrc : b.colorSrc, b.separateAlpha ? b.alphaDst : b.colorDst,
                              b.separateAlpha ? b.alphaFunc : b.colorFunc};
        }
    }
    e.renderer->draw(d);
    if (VideoCore::Shadow::Side* side = shadowSide()) {
        // The definitions of Vulkan's half (shadow_record.h): `cleared` is what the renderer reports (its pass starts with
        // a clear of the target: Resolved::color[].cleared, shadowResolved), the depth target is used when the draw
        // tests or writes it. Kept to what the renderer reports: a target it does not hold stays unused.
        side->depth.used = side->depth.used && ((dc.depth_enable && db.DepthValid()) || (dc.stencil_enable && db.StencilValid()));
    }
    if (pixels && VideoCore::Shadow::PixelsAvailable().load(std::memory_order_relaxed)) {
        @autoreleasepool {
            try {
                pixelEngine().draw(*pixels, pixelClear ? &*pixelClear : nullptr, d);
            } catch (const std::exception& ex) {
                VideoCore::Shadow::PixelsAvailable().store(false, std::memory_order_relaxed);
                pixels->vpkSkip = "exception";
                LOG_ERROR(Render_Vulkan, "ASTRO_PIXEL disabled reason={}", ex.what());
            } catch (...) {
                VideoCore::Shadow::PixelsAvailable().store(false, std::memory_order_relaxed);
                pixels->vpkSkip = "exception";
                LOG_ERROR(Render_Vulkan, "ASTRO_PIXEL disabled reason=unknown exception");
            }
        }
    }
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
    VideoCore::Shadow::Side* shadow_side = shadowBegin("left before the renderer (no compute program)");
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
    if (shadow_side) {
        shadow_side->hash[size_t(VideoCore::Shadow::Stage::Cs)] = params.hash;
        if (!indirect) shadow_side->groups = {cs.dim_x, cs.dim_y, cs.dim_z};
    }
    e.renderer->dispatch(d);
    e.noteWork();
}

void Rasterizer::FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds) {
    if (VideoCore::Shadow::Side* side = shadowBegin(is_gds ? "GDS fill" : "left before the renderer")) {
        side->dst = address, side->bytes = num_bytes, side->value = value;
    }
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
    // A fill of HTILE with cleared entries is a depth clear: noted, the fill itself is left out. Any other fill
    // of a metadata surface marks it cleared (and is done).
    if (value != 0 && e.metas.TryHtileClear(address, std::span{&value, 1})) {
        ++e.metaDma;
        e.noteHtileCleared(address);
        if (VideoCore::Shadow::Side* side = shadowSide()) side->status = VideoCore::Shadow::Status::Drawn, side->reason.clear();
        return;
    }
    if (e.metas.ClearAll(address)) ++e.metaDma;
    // The shadow only records the DMA on its own GPU timeline (the null backend drops it): the bytes are the real
    // renderer's to write, and the shadow's images over the range learn that it changed.
    if (e.shadow) {
        e.renderer->fill(address, num_bytes, value);
        e.noteWork();
        return;
    }
    // DMA runs on the CPU, in order, when queued GPU work does not touch the range (the renderer keeps the guest ranges
    // bound since the GPU was last idle): the bytes are written at once, no submit, no wait. Memory is unified, so the
    // command processor and the title may read them right after this packet. When the GPU does touch the range, the fill goes
    // on the GPU timeline, in order with that work, with no wait and no submit (what shadPS4 does too): whoever reads it
    // on the CPU (the command processor: IB, labels, WAIT_REG_MEM) goes through SyncGpuWrites / syncForDma and waits for it.
    // (VPKENGINE_DMA_CPU=1: it waits and writes in place, as before.) A fill the renderer refuses (no staging) waits too.
    if (e.syncForDma(address, num_bytes, 0, 0, "fill", true)) {
        if (e.renderer->fill(address, num_bytes, value)) {
            e.noteDmaOnGpu();
            e.noteWork();
            if (e.scheduler) e.scheduler->forgetLabelValues(address, num_bytes);
            return;
        }
        e.syncForDma(address, num_bytes, 0, 0, "fill");
    }
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
    if (e.scheduler) e.scheduler->forgetLabelValues(address, num_bytes);
}

void Rasterizer::CopyBuffer(VAddr dst, VAddr src, u32 num_bytes, bool dst_gds, bool src_gds) {
    if (VideoCore::Shadow::Side* side = shadowBegin(dst_gds || src_gds ? "GDS copy" : "left before the renderer")) {
        side->dst = dst, side->src = src, side->bytes = num_bytes;
    }
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
            // (the source is read on the CPU: a DMA recorded on the GPU timeline over it lands first)
            if (!e.shadow) e.syncForDma(src, num_bytes, 0, 0, "gds_copy");
            if (dst < 0x10000 && readable(src, num_bytes) >= num_bytes)
                std::memcpy(gb + dst, reinterpret_cast<const void*>(src), std::min<u64>(num_bytes, 0x10000 - dst));
        } else if (src < 0x10000 && readable(dst, num_bytes) >= num_bytes) {
            if (e.shadow) {
                // GDS into guest memory is the real renderer's write: the shadow only learns that the range changed.
                e.renderer->invalidate(dst, num_bytes);
            } else {
                e.syncForDma(dst, num_bytes, 0, 0, "gds_copy");  // (written on the CPU: after a DMA recorded on the GPU timeline)
                std::memcpy(reinterpret_cast<void*>(dst), gb + src, std::min<u64>(num_bytes, 0x10000 - src));
                impl->invalidate(dst, num_bytes);
            }
        }
        return;
    }
    // A copy of HTILE entries that are mostly cleared (a template the title prepared) is a depth clear: noted,
    // the copy itself is left out.
    if (e.metas.IsHtile(dst)) {
        if (!e.shadow) e.syncForDma(src, num_bytes, 0, 0, "htile_src");
        if (readable(src, num_bytes) >= num_bytes &&
            e.metas.TryHtileClear(dst, std::span{reinterpret_cast<const u32*>(src), num_bytes / sizeof(u32)})) {
            ++e.metaDma;
            e.noteHtileCleared(dst);
            if (VideoCore::Shadow::Side* side = shadowSide()) side->status = VideoCore::Shadow::Status::Drawn, side->reason.clear();
            return;
        }
    }
    if (e.shadow) {  // (recorded only, as in FillBuffer)
        e.renderer->copy(dst, src, num_bytes);
        e.noteWork();
        return;
    }
    // On the CPU and in order, for the same reason as FillBuffer (synced only when needed; on the GPU timeline when the GPU
    // touches either range, unless they overlap: a memmove is not a GPU copy).
    if (e.syncForDma(src, num_bytes, dst, num_bytes, "copy", !(src < dst + num_bytes && dst < src + num_bytes))) {
        if (e.renderer->copy(dst, src, num_bytes)) {
            e.noteDmaOnGpu();
            e.noteWork();
            if (e.scheduler) e.scheduler->forgetLabelValues(dst, num_bytes);
            return;
        }
        e.syncForDma(src, num_bytes, dst, num_bytes, "copy");
    }
    if (readable(src, num_bytes) < num_bytes || readable(dst, num_bytes) < num_bytes) {
        e.renderer->copy(dst, src, num_bytes);
        e.noteWork();
        return;
    }
    std::memmove(reinterpret_cast<void*>(dst), reinterpret_cast<const void*>(src), num_bytes);
    e.renderer->invalidate(dst, num_bytes);
    if (e.scheduler) e.scheduler->forgetLabelValues(dst, num_bytes);
}

u32 Rasterizer::ReadDataFromGds(u32 gds_offset) {
    Engine& e = engine();
    std::scoped_lock g{e.lock};
    if (!e.renderer) return 0;
    u32* gds = e.renderer->gds();
    return gds && gds_offset < 0x10000 ? gds[gds_offset / 4] : 0;
}

bool Rasterizer::InvalidateMemory(VAddr addr, u64 size) {
    if (impl->shadow) {  // (nothing is protected or owned here: the renderer only drops what it made from the range)
        engine().queueInvalidate(addr, std::max<u64>(size, 1));
        return false;
    }
    if (!impl->isMapped(addr, std::max<u64>(size, 1))) return false;
    const bool owned = impl->resolveOwned(addr, 1, true);
    return impl->invalidate(addr, std::max<u64>(size, 1)) || owned;
}

// A CPU access faulted on the host page [page, page + size): the host protects it whole, so
// everything watched or owned anywhere in it is let go of (a watch that starts elsewhere in the page
// than the access keeps the page protected, and the access faults for ever). Letting go of more than
// the access touched costs a refill of the texture, not a wrong picture.
bool Rasterizer::InvalidateHostPage(VAddr page, u64 size, bool write) {
    if (!impl->anyMapped(page, size)) return false;
    const bool owned = impl->resolveOwned(page, size, write);
    return (write && impl->invalidate(page, size)) || owned;
}

// The CPU read memory that an image on the GPU is ahead of (render targets are not written back by
// themselves): the renderer re-tiles the image into the guest memory, the GPU finishes it, and the
// read is retried.
bool Rasterizer::ReadMemory(VAddr addr, u64 size) {
    if (!impl->isMapped(addr, std::max<u64>(size, 1))) return false;
    return impl->resolveOwned(addr, 1, false);
}

bool Rasterizer::Impl::resolveOwned(VAddr addr, u64 n, bool write) {
    const auto hit = ownedIn(addr, n);
    // (another thread resolved this page between the fault and here: the access is retried)
    if (hit.empty()) return recentlyReleasedOwned(addr, n);
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
            for (auto [s, z] : hit) e.syncForDma(s, z, 0, 0, "owned_fault");
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
                // (one watcher per key, whatever the count: see setOwned)
                page_manager->UpdateReadWatchers<false>(s, z);
                page_manager->UpdatePageWatchers<false>(s, z);
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
                    page_manager->UpdateReadWatchers<false>(s, z);
                    page_manager->UpdatePageWatchers<false>(s, z);
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
    if (impl->page_manager) impl->page_manager->OnGpuMap(addr, size);
    spanCache().clear();
}

void Rasterizer::UnmapMemory(VAddr addr, u64 size) {
    impl->invalidate(addr, size);
    // The memory is gone whatever was watched there: the tracker forgets what it knew (stale owners
    // included) and textures made from it are refilled if the range is mapped again.
    engine().queueInvalidate(addr, size);
    engine().queueUnmap(addr, size);
    impl->dropOwned(addr, size);
    if (impl->page_manager) impl->page_manager->OnGpuUnmap(addr, size);
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
    if (e.shadow) return false;  // (the results are written into guest memory)
    std::scoped_lock g{e.lock};
    if (!e.start()) return false;
    e.applyPending();
    return e.renderer->zpassDone(address, pairs);
}

// The command processor reads occlusion results (SET_PREDICATION, OCCLUSION_QUERY): with `wait`
// the GPU is finished first (submit + wait, then the results are written).
bool Rasterizer::SyncGpuWrites(VAddr addr, u64 size, bool wait) {
    Engine& e = engine();
    if (e.shadow) return true;  // (it writes nothing the command processor could wait for)
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
            e.syncForDma(a, n, 0, 0, "cp_read");
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
    // (The shadow's picture ends at the flip, ShadowEndFrame: its frame goes out here, on the thread that records it.)
    if (e.scheduler) {
        if (e.shadow && gShadowFlip.exchange(false, std::memory_order_acq_rel)) e.scheduler->present();
        else e.scheduler->flush();
    }
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
    if (e.shadow) return;  // (the label and its interrupt are the real renderer's)
    // VPKENGINE_LABELS_IMMEDIATE=1 (off by default): the label is written, and its interrupt raised, when it is processed
    // and not when the GPU has finished the work before it, as the reference command processor does. That saves a GPU round
    // trip per batch a title submits, but here the label is also what keeps the title from reusing memory that recorded
    // draws still read in place (buffers are bound from guest memory, not copied) and from reading what the GPU has yet to
    // write outside the watched images: only for measuring. A DMA recorded on the GPU timeline over the label's bytes is
    // waited for (it must land first).
    static const bool ordered = std::getenv("VPKENGINE_LABELS_IMMEDIATE") == nullptr;
    if (!ordered) {
        {
            std::scoped_lock g{e.lock};
            if (e.scheduler && address) {
                e.applyPending();
                e.syncForDma(reinterpret_cast<u64>(address), size, 0, 0, "label");
            }
            ++e.labelsImmediate;
        }
        if (address) VideoCore::WriteGuestLabel(address, value, size);
        if (then) then();
        return;
    }
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
    if (e.shadow) return false;
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
    if (e.shadow) return false;
    uint64_t target = 0;
    {
        std::scoped_lock g{e.lock};
        if (!e.scheduler) return false;
        target = e.scheduler->idleTarget(reinterpret_cast<u64>(address), size);
    }
    if (!target) return false;
    // The wait itself is outside the engine lock: the other queues, the compositor and the recording
    // thread keep running meanwhile. Then a short sleep gives them the core.
    e.scheduler->waitGpu(target, 2);
    {
        std::scoped_lock g{e.lock};
        if (e.scheduler) e.scheduler->pumpLabels();
    }
    std::this_thread::sleep_for(std::chrono::microseconds{50});
    return true;
}

void Rasterizer::WriteDataOrdered(void* address, const void* data, u32 size) {
    Engine& e = engine();
    if (e.shadow) return;  // (guest memory is the real renderer's to write)
    {
        std::scoped_lock g{e.lock};
        // After the GPU work that reads or writes this memory, and after label writes pending for it.
        if (e.scheduler) {
            // Images ahead of this memory are written back first (and their pages released once the GPU
            // has run that): a protected page would fault in the middle of the copy.
            if (e.renderer) e.renderer->syncToMemory(reinterpret_cast<u64>(address), size);
            e.scheduler->syncCpu(reinterpret_cast<u64>(address), size, vpgpu::SubmitReason::WriteData);
            std::memcpy(address, data, size);
            e.scheduler->forgetLabelValues(reinterpret_cast<u64>(address), size);
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
        const vpgpu::TextureId tid = e.renderer->textureFor(d);
        if (!tid) return nil;
        return nativeTexture(e, tid);
    }

    // The Metal texture of `tid` (with the submit thread, if there is one, kept out of the backend meanwhile).
    static id<MTLTexture> nativeTexture(Engine& e, vpgpu::TextureId tid) {
        void* native = nullptr;
        e.device->withBackend([&] { native = e.backend->nativeTexture(tid); });
        return (__bridge id<MTLTexture>)native;
    }

    // Draws `regions` into a new headset frame of width x height; -1 if the host has none free.
    // ---- EYE_STATS: what each eye picture holds, every 2 s (a black picture shows as luma 0, 0 % lit).
    // A compute kernel reduces each eye to 64x64 blocks (strided samples of each) in a small persistent
    // shared buffer; the completion handler adds up 4096 entries. Nothing is copied, nothing big is read.
    static constexpr u32 kStatsGrid = 64;
    std::chrono::steady_clock::time_point stats_at{};
    std::atomic<bool> stats_busy{false};
    id<MTLComputePipelineState> stats_pso{nil};
    std::array<id<MTLBuffer>, 2> stats_buf{};

    // ---- EYE_CHAIN: the same reduction on the texture the eye pass's pixel shader samples and on the
    // guest-level resolve destinations over it (slot 0 the source, then the resolves). The renderer's draw
    // probes (armed for the picture before the 2 s mark) say which T# that is.
    static constexpr u32 kChainMax = 3;
    std::array<id<MTLBuffer>, kChainMax> chain_buf{};
    struct Chain {
        bool valid = false;  // probes were armed: the line is logged
        std::array<id<MTLTexture>, kChainMax> tex{};
        std::array<std::string, kChainMax> label{}, tail{};
    };
    bool probes_on = false;  // probes armed for the picture being drawn
    std::vector<vpps4::Renderer::DrawProbe> snap;  // the draws of the picture just composed (when probes were on)
    std::vector<Engine::ResolveNote> snap_resolves;
    bool snap_valid = false;
    u32 gs_logs = 0, gs_none = 0;  // EYE_GS lines started / "none" lines (4 each per session)

    // Under build_mutex (with the compose pipeline, off the first frame's path).
    void buildStatsPipeline(id<MTLDevice> dev) {
        static const char* kSource = R"MSL(
#include <metal_stdlib>
using namespace metal;
kernel void vp_eye_stats(texture2d<float, access::read> t [[texture(0)]], device float2* out [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    const uint w = t.get_width(), h = t.get_height();
    const uint x0 = gid.x * w / 64, x1 = (gid.x + 1) * w / 64, y0 = gid.y * h / 64, y1 = (gid.y + 1) * h / 64;
    const uint sx = max((x1 - x0) / 8, 1u), sy = max((y1 - y0) / 8, 1u);
    float l = 0, nz = 0, n = 0;
    for (uint y = y0; y < y1; y += sy)
        for (uint x = x0; x < x1; x += sx) {
            const float4 c = t.read(uint2(x, y));
            l += (c.r + c.g + c.b) / 3.0;
            nz += (c.r > 0 || c.g > 0 || c.b > 0) ? 1.0 : 0.0;
            n += 1.0;
        }
    out[gid.y * 64 + gid.x] = float2(l / max(n, 1.0), nz / max(n, 1.0));
}
)MSL";
        NSError* error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSource) options:nil error:&error];
        id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"vp_eye_stats"] : nil;
        if (fn) stats_pso = [dev newComputePipelineStateWithFunction:fn error:&error];
        for (auto& b : stats_buf) b = [dev newBufferWithLength:kStatsGrid * kStatsGrid * sizeof(float) * 2
                                                       options:MTLResourceStorageModeShared];
        for (auto& b : chain_buf) b = [dev newBufferWithLength:kStatsGrid * kStatsGrid * sizeof(float) * 2
                                                       options:MTLResourceStorageModeShared];
        if (!stats_pso) LOG_WARNING(Render_Vulkan, "EYE_STATS kernel unavailable");
    }

    // ---- EYE probe (diagnostics): every picture, per eye, the mean luma, the share of lit samples and a hash of the
    // sampled texels (a frozen picture repeats it), with the draws that wrote the eye's target. The reduction is the stats
    // kernel's grid (64x64 cells of strided samples) with the texels' bits folded into a hash; one small shared buffer per
    // eye and slot, summed by the completion handler. A slot still in use makes the picture count as skipped.
    static constexpr u32 kHashSlots = 4;
    id<MTLComputePipelineState> hash_pso{nil};
    std::array<std::array<id<MTLBuffer>, 2>, kHashSlots> hash_buf{};
    std::atomic<u32> hash_busy{0};
    std::mutex hash_mutex;                   // the previous hash per eye (completion handlers of different pictures)
    std::array<u64, 2> hash_prev{};
    std::array<bool, 2> hash_has_prev{};
    u32 hash_slot = 0;

    void buildHashPipeline(id<MTLDevice> dev) {
        static const char* kSource = R"MSL(
#include <metal_stdlib>
using namespace metal;
kernel void vp_eye_hash(texture2d<float, access::read> t [[texture(0)]], device uint4* out [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    const uint w = t.get_width(), h = t.get_height();
    const uint x0 = gid.x * w / 64, x1 = (gid.x + 1) * w / 64, y0 = gid.y * h / 64, y1 = (gid.y + 1) * h / 64;
    const uint sx = max((x1 - x0) / 8, 1u), sy = max((y1 - y0) / 8, 1u);
    float l = 0;
    uint nz = 0, n = 0, hash = 2166136261u;
    for (uint y = y0; y < y1; y += sy)
        for (uint x = x0; x < x1; x += sx) {
            const float4 c = t.read(uint2(x, y));
            const uint4 b = as_type<uint4>(c);
            hash = (((hash ^ b.x) * 16777619u ^ b.y) * 16777619u ^ b.z) * 16777619u ^ b.w;
            hash *= 16777619u;
            l += (c.r + c.g + c.b) / 3.0f;
            nz += (c.r > 0 || c.g > 0 || c.b > 0) ? 1u : 0u;
            ++n;
        }
    out[gid.y * 64 + gid.x] = uint4(uint(min(l / float(max(n, 1u)), 4000.0f) * 1000000.0f), nz, hash, n);
}
)MSL";
        NSError* error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:@(kSource) options:nil error:&error];
        id<MTLFunction> fn = lib ? [lib newFunctionWithName:@"vp_eye_hash"] : nil;
        if (fn) hash_pso = [dev newComputePipelineStateWithFunction:fn error:&error];
        for (auto& slot : hash_buf)
            for (auto& b : slot)
                b = [dev newBufferWithLength:kStatsGrid * kStatsGrid * sizeof(u32) * 4 options:MTLResourceStorageModeShared];
        if (!hash_pso) LOG_WARNING(Render_Vulkan, "VPKENGINE_PROBE eye hash kernel unavailable");
    }

    // The reduction of one picture, encoded inside the headset frame's own command buffer (compose): no command buffer, frame
    // slot or drain of its own, so it does not disturb the slot wait or the submit times it is there to measure.
    struct HashJob {
        int slot = -1;  // -1: none this picture
        std::array<id<MTLTexture>, 2> src{};
        std::array<id<MTLBuffer>, 2> bufs{};
    };
    HashJob hash_job;

    // Under the engine lock, after the eyes' drawing is submitted (like eyeStats); compose() carries the job out.
    void eyeProbe(Engine& e, const std::array<id<MTLTexture>, 2>& eyes, const std::array<vpps4::ImageDesc, 2>& eyeDesc) {
        static pm::Counter* pictures = &pm::counter("EYE", "pictures");
        static std::array<pm::Counter*, 2> draws{&pm::counter("EYE", "eye0_draws"), &pm::counter("EYE", "eye1_draws")};
        static std::array<pm::Hist*, 2> drawsPerPicture{&pm::hist("EYE", "eye0_draws_per_picture"), &pm::hist("EYE", "eye1_draws_per_picture")};
        static pm::Counter* skipped = &pm::counter("EYE", "reduction_skipped");
        e.pictures.fetch_add(1, std::memory_order_relaxed);
        pictures->add();
        // (the eye pair as slices of one array target: the draws are counted under the eye whose T# is the target's address)
        for (u32 k = 0; k < 2; ++k) {
            const u64 n = e.renderer->takeTargetDraws(eyeDesc[k].address, 0, 0);
            draws[k]->add(n);
            drawsPerPicture[k]->add(n);
        }
        {
            std::scoped_lock built{build_mutex};
            if (!hash_pso && !hash_buf[0][0]) buildHashPipeline((__bridge id<MTLDevice>)e.backend->nativeDevice());
        }
        if (!hash_pso) return;
        // (the same test as the chain's reduction: a float-readable single-sample 2D picture with memory; the eyes are 2D already,
        // an array target's slice was made a 2D view by ComposeEyes)
        HashJob job;
        for (u32 k = 0; k < 2; ++k) {
            if (!eyes[k]) continue;
            job.src[k] = reducible(eyes[k], 0);
            if (!job.src[k]) skipped->add();
        }
        if (!job.src[0] && !job.src[1]) return;
        const u32 slot = hash_slot++ % kHashSlots;
        if (hash_busy.fetch_or(1u << slot) & (1u << slot)) {
            skipped->add();
            return;
        }
        job.slot = int(slot);
        job.bufs = hash_buf[slot];
        dropHashJob(hash_job);  // (a job no compose carried out: its slot goes back first)
        hash_job = job;
    }

    // Gives back the slot of a job that was not carried out.
    void dropHashJob(const HashJob& job) {
        if (job.slot >= 0) hash_busy.fetch_and(~(1u << job.slot));
    }

    // Encodes a job's compute pass (into the command buffer of the headset frame).
    void encodeHashJob(id<MTLCommandBuffer> cb, const HashJob& job) {
        if (job.slot < 0) return;
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        enc.label = @"eye probe";
        [enc setComputePipelineState:hash_pso];
        for (u32 k = 0; k < 2; ++k) {
            if (!job.src[k]) continue;
            [enc setTexture:job.src[k] atIndex:0];
            [enc setBuffer:job.bufs[k] offset:0 atIndex:0];
            [enc dispatchThreads:MTLSizeMake(kStatsGrid, kStatsGrid, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        }
        [enc endEncoding];
    }

    // The headset frame's completion handler: sums the job's buffers.
    void finishHashJob(const HashJob& job) {
        if (job.slot < 0) return;
        for (u32 k = 0; k < 2; ++k)
            if (job.src[k]) noteEyeHash(k, job.bufs[k]);
        dropHashJob(job);
    }

    // Completion handler: sums a filled hash buffer into the EYE metrics (luma, lit share, blank and frozen pictures).
    void noteEyeHash(u32 eye, id<MTLBuffer> buf) {
        const u32* v = static_cast<const u32*>(buf.contents);
        double luma = 0;
        u64 lit = 0, samples = 0, hash = 14695981039346656037ull;
        for (u32 i = 0; i < kStatsGrid * kStatsGrid; ++i) {
            luma += double(v[4 * i]) / 1e6;
            lit += v[4 * i + 1];
            samples += v[4 * i + 3];
            hash = (hash ^ v[4 * i + 2]) * 1099511628211ull;
        }
        const std::string name = "eye" + std::to_string(eye) + "_";
        pm::counter("EYE", name + "frames").add();
        pm::hist("EYE", name + "luma_milli").add(u64(luma / (kStatsGrid * kStatsGrid) * 1000.0));
        pm::hist("EYE", name + "lit_permille").add(samples ? lit * 1000 / samples : 0);
        if (lit == 0) pm::counter("EYE", name + "blank").add();
        bool frozen = false;
        {
            std::scoped_lock l{hash_mutex};
            frozen = hash_has_prev[eye] && hash_prev[eye] == hash;
            hash_prev[eye] = hash;
            hash_has_prev[eye] = true;
        }
        if (frozen) pm::counter("EYE", name + "frozen").add();
        pm::registry().info("EYE", name + "hash", fmt::format("{:016x}", hash));
    }

    // (average luma, % of samples lit) of a filled stats buffer.
    static std::pair<double, double> reduced(id<MTLBuffer> buf) {
        const float* v = static_cast<const float*>(buf.contents);
        double luma = 0, lit = 0;
        for (u32 i = 0; i < kStatsGrid * kStatsGrid; ++i) luma += v[2 * i], lit += v[2 * i + 1];
        const double n = kStatsGrid * kStatsGrid;
        return {luma / n, 100.0 * lit / n};
    }

    static void logEyeStats(u32 eye, u32 w, u32 h, u32 format, id<MTLBuffer> buf) {
        const std::pair<double, double> r = reduced(buf);
        LOG_INFO(Render_Vulkan, "EYE_STATS eye {} {}x{} format {} avg_luma {:.4f} non_zero {:.1f}%", eye, w, h, format,
                 r.first, r.second);
    }

    // A 2D single-sample picture of `t` (slice `layer` of an array one) the stats kernel can read; nil if it is not
    // one (integer, depth or stencil formats would not match the kernel's float texture; memoryless has no contents).
    static id<MTLTexture> reducible(id<MTLTexture> t, u16 layer) {
        if (!t || t.sampleCount != 1 || !(t.usage & MTLTextureUsageShaderRead) || t.storageMode == MTLStorageModeMemoryless)
            return nil;
        switch (t.pixelFormat) {
        case MTLPixelFormatInvalid:
        case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatR16Uint: case MTLPixelFormatR16Sint: case MTLPixelFormatRG16Uint: case MTLPixelFormatRG16Sint:
        case MTLPixelFormatR32Uint: case MTLPixelFormatR32Sint: case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint:
        case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGBA8Sint: case MTLPixelFormatRGBA16Uint:
        case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint:
        case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatDepth16Unorm: case MTLPixelFormatDepth32Float:
        case MTLPixelFormatStencil8: case MTLPixelFormatDepth32Float_Stencil8: case MTLPixelFormatX32_Stencil8:
            return nil;
        default: break;
        }
        if (t.textureType == MTLTextureType2D) return layer == 0 ? t : nil;
        if (t.textureType == MTLTextureType2DArray && layer < t.arrayLength)
            return [t newTextureViewWithPixelFormat:t.pixelFormat
                                        textureType:MTLTextureType2D
                                             levels:NSMakeRange(0, 1)
                                             slices:NSMakeRange(layer, 1)];
        return nil;
    }

    // The record of the eye pass among the draws of the last picture: what wrote eye 0's target, else eye 1's.
    static const vpps4::Renderer::DrawProbe* findProbe(const std::vector<vpps4::Renderer::DrawProbe>& probes, u64 address) {
        for (const vpps4::Renderer::DrawProbe& p : probes)
            if (p.colorAddress == address) return &p;
        return nullptr;
    }
    const vpps4::Renderer::DrawProbe* eyeProbe(const std::array<vpps4::ImageDesc, 2>& eyeDesc) const {
        const vpps4::Renderer::DrawProbe* p = findProbe(snap, eyeDesc[0].address);
        return p ? p : findProbe(snap, eyeDesc[1].address);
    }

    // The texture the eye pass's pixel shader samples, and the guest-level resolve destinations over it, as textures to
    // reduce (or the reason there are none). Under the engine lock, with `snap` filled.
    Chain chainOf(Engine& e, const std::array<vpps4::ImageDesc, 2>& eyeDesc) {
        Chain c;
        c.valid = true;
        c.label[0] = "src=unknown";
        vpps4::ImageDesc anchor = eyeDesc[0];  // what the resolves are matched with: the sampled T#, else the eye itself
        const vpps4::Renderer::DrawProbe* p = eyeProbe(eyeDesc);
        if (!p) {
            c.tail[0] = " (no draw wrote the eye target in the last picture)";
        } else if (!p->hasPsTexture) {
            c.tail[0] = " (the eye pass pixel shader samples no texture)";
        } else {
            const vpps4::ImageDesc& s = p->psTexture;
            anchor = s;
            uint16_t layer = 0;
            std::string kind;
            const vpgpu::TextureId tid = e.renderer->backingAt(s, layer, kind);
            if (!tid) {
                c.label[0] = fmt::format("src=unbacked T# {:#x}", s.address);
                c.tail[0] = fmt::format(" {}x{} fmt {}/{} (no GPU surface backs it: guest memory only)", s.width, s.height,
                                        u32(s.dataFormat), u32(s.numFormat));
            } else {
                c.label[0] = fmt::format("src={:#x}", s.address);
                c.tex[0] = reducible(nativeTexture(e, tid), layer);
                c.tail[0] = fmt::format(" ({}{})", kind, c.tex[0] ? "" : "; the kernel cannot read it");
            }
        }
        auto bytes = [](const vpps4::ImageDesc& d) { return u64(std::max(d.pitch, d.width)) * d.height * 8; };
        const u64 a0 = anchor.address, a1 = a0 + bytes(anchor);
        u32 n = 1;
        for (const Engine::ResolveNote& r : snap_resolves) {
            if (n >= kChainMax) break;
            vpps4::ImageDesc q;
            q.address = r.address;
            q.width = r.width;
            q.height = r.height;
            q.pitch = r.pitch;
            if (r.address >= a1 || a0 >= r.address + bytes(q)) continue;  // does not overlap
            uint16_t layer = 0;
            std::string kind;
            const vpgpu::TextureId tid = e.renderer->backingAt(q, layer, kind);
            c.label[n] = fmt::format("resolve@{:#x}", r.address);
            if (!tid) {
                c.tail[n] = fmt::format(" {}x{} (unbacked)", r.width, r.height);
            } else {
                c.tex[n] = reducible(nativeTexture(e, tid), layer);
                c.tail[n] = fmt::format(" ({}{})", kind, c.tex[n] ? "" : "; the kernel cannot read it");
            }
            ++n;
        }
        return c;
    }

    static void logChain(const Chain& c, const std::array<id<MTLBuffer>, kChainMax>& cbufs,
                         const std::array<id<MTLTexture>, 2>& eyes, const std::array<id<MTLBuffer>, 2>& ebufs) {
        std::string line = "EYE_CHAIN";
        for (u32 i = 0; i < kChainMax; ++i) {
            if (c.label[i].empty()) continue;
            line += i == 0 ? " " : " | ";
            line += c.label[i];
            if (c.tex[i] && cbufs[i]) {
                const std::pair<double, double> r = reduced(cbufs[i]);
                line += fmt::format(" {}x{} fmt {} luma {:.4f} non_zero {:.1f}%", u32(c.tex[i].width), u32(c.tex[i].height),
                                    u32(c.tex[i].pixelFormat), r.first, r.second);
            }
            line += c.tail[i];
        }
        for (u32 k = 0; k < 2; ++k)
            if (eyes[k] && ebufs[k]) {
                const std::pair<double, double> r = reduced(ebufs[k]);
                line += fmt::format(" | eye {} luma {:.4f} non_zero {:.1f}%", k, r.first, r.second);
            }
        LOG_INFO(Render_Vulkan, "{}", line);
    }

    // EYE_PS (diagnostics, every 120 pictures): the first T# of the eye pass's pixel shader.
    void logEyePs(Engine& e, const std::array<vpps4::ImageDesc, 2>& eyeDesc) const {
        const vpps4::Renderer::DrawProbe* p = eyeProbe(eyeDesc);
        if (!p || !p->hasPsTexture) {
            LOG_INFO(Render_Vulkan, "EYE_PS eye target {:#x}: {}", eyeDesc[0].address,
                     p ? "its last draw's pixel shader samples no texture" : "no draw wrote it in the last picture");
            return;
        }
        const vpps4::ImageDesc& s = p->psTexture;
        uint16_t layer = 0;
        std::string kind;
        const bool backed = bool(e.renderer->backingAt(s, layer, kind));
        LOG_INFO(Render_Vulkan,
                 "EYE_PS eye target {:#x} (geometry draw {}): PS T# {:#x} tile {} pitch {} fmt {}/{} {}x{} type {} backing: {}",
                 eyeDesc[0].address, p->geom, s.address, u32(s.tilingIndex), s.pitch, u32(s.dataFormat), u32(s.numFormat),
                 s.width, s.height, u32(s.type), backed ? kind : std::string("none (guest memory only)"));
    }

    // EYE_GS, read once the frame is done: indices of the GS output list that are not padding (0xffffffff) and the w of
    // the first 16 vertices they name, taken as component 3 of the copy shader's ring (position assumed to be the first
    // four components the GS writes; v0 shows them raw). Ring layout: vpgcn/geom.h (copy load).
    static void logEyeGs(const u32* index, u64 count, const u32* ring, u64 ringDwords, u32 maxVert) {
        constexpr u64 kScan = 1ull << 23;
        const u64 n = std::min(count, kScan);
        const u64 plane = u64(maxVert) * 16;  // dwords between the components of a vertex
        u64 prims = 0, shown = 0, outside = 0, nonFinite = 0;
        float wMin = 0, wMax = 0;
        std::array<float, 4> v0{};
        for (u64 i = 0; i < n; ++i) {
            const u32 v = index[i];
            if (v == 0xffffffffu) continue;
            ++prims;
            if (shown >= 16) continue;
            if (u64(v) + 3 * plane >= ringDwords) {
                ++outside;
                continue;
            }
            std::array<float, 4> c{};
            for (u32 k = 0; k < 4; ++k) std::memcpy(&c[k], &ring[u64(v) + k * plane], sizeof(float));
            if (!std::isfinite(c[3])) {
                ++nonFinite;
            } else {
                wMin = shown == 0 ? c[3] : std::min(wMin, c[3]);
                wMax = shown == 0 ? c[3] : std::max(wMax, c[3]);
            }
            if (shown == 0) v0 = c;
            ++shown;
        }
        LOG_INFO(Render_Vulkan,
                 "EYE_GS prims={} (indices not 0xffffffff, of {} scanned/{} total) w_min {} w_max {} (first {} vertices; "
                 "{} outside the ring, {} w not finite; v0 = {} {} {} {})",
                 prims, n, count, wMin, wMax, shown, outside, nonFinite, v0[0], v0[1], v0[2], v0[3]);
    }

    // Under the engine lock, after the eyes' drawing is submitted: reduces both eyes behind it on the queue.
    void eyeStats(Engine& e, const std::array<id<MTLTexture>, 2>& eyes, const std::array<vpps4::ImageDesc, 2>& eyeDesc) {
        const auto now = std::chrono::steady_clock::now();
        // The draw probes of the picture just composed (armed for it, see below).
        snap.clear();
        snap_resolves.clear();
        snap_valid = probes_on;
        if (probes_on) {
            snap = e.renderer->takeProbes();
            snap_resolves.swap(e.resolves);
        }
        const bool due = now - stats_at >= std::chrono::seconds{2};
        const bool diagnostics = Common::Diagnostics();
        if (diagnostics && snap_valid && frames % 120 == 0) logEyePs(e, eyeDesc);
        // Probes for the next picture: the ones before the 2 s mark (EYE_CHAIN) and, in diagnostics, before every
        // 120th picture (EYE_PS, EYE_GS). Outside those pictures the renderer records nothing.
        const bool arm = (!due && now - stats_at >= std::chrono::milliseconds{1800}) || (diagnostics && frames % 120 == 119);
        if (arm != probes_on) {
            e.armProbes(arm);
            probes_on = arm;
        }
        if (!due) return;
        stats_at = now;
        {
            std::scoped_lock built{build_mutex};
            if (!stats_pso && !stats_buf[0]) buildStatsPipeline((__bridge id<MTLDevice>)e.backend->nativeDevice());
        }
        if (!stats_pso) return;
        std::array<id<MTLTexture>, 2> src{};
        for (u32 k = 0; k < 2; ++k)
            if (eyes[k] && eyes[k].textureType == MTLTextureType2D && eyes[k].sampleCount == 1) src[k] = eyes[k];
        if (!src[0] && !src[1] && !snap_valid) return;
        if (stats_busy.exchange(true)) return;
        Chain chain;
        if (snap_valid) chain = chainOf(e, eyeDesc);
        bool anyChain = false;
        for (u32 i = 0; i < kChainMax; ++i)
            if (chain.tex[i]) anyChain = true;
        if (!src[0] && !src[1] && !anyChain) {
            logChain(chain, {}, src, {});  // nothing to reduce: the line says why
            stats_busy = false;
            return;
        }
        const auto pso = stats_pso;
        const auto bufs = stats_buf;
        const auto cbufs = chain_buf;
        // The reduction goes after the frames submitted before it: with the submit thread, they must
        // have reached the backend (as in compose()).
        e.device->drain();
        bool queued = false;
        e.device->withBackend([&] { queued = e.backend->encodeInterop(
            [&](void* cbp) {
                id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
                id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
                enc.label = @"eye stats";
                [enc setComputePipelineState:pso];
                for (u32 k = 0; k < 2; ++k) {
                    if (!src[k]) continue;
                    [enc setTexture:src[k] atIndex:0];
                    [enc setBuffer:bufs[k] offset:0 atIndex:0];
                    [enc dispatchThreads:MTLSizeMake(kStatsGrid, kStatsGrid, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                }
                for (u32 i = 0; i < kChainMax; ++i) {
                    if (!chain.tex[i]) continue;
                    [enc setTexture:chain.tex[i] atIndex:0];
                    [enc setBuffer:cbufs[i] offset:0 atIndex:0];
                    [enc dispatchThreads:MTLSizeMake(kStatsGrid, kStatsGrid, 1) threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                }
                [enc endEncoding];
            },
            "vp.eyestats",
            [this, src, bufs, chain, cbufs] {
                for (u32 k = 0; k < 2; ++k)
                    if (src[k]) logEyeStats(k, u32(src[k].width), u32(src[k].height), u32(src[k].pixelFormat), bufs[k]);
                if (chain.valid) logChain(chain, cbufs, src, bufs);
                stats_busy = false;
            }); });
        if (!queued) stats_busy = false;
    }

    // EYE_GS (diagnostics, the first 4 pictures every 120th that have one): the eye pass's geometry-shader output, read from
    // the scratch slab's host memory once the GPU has finished the frame (a command buffer behind it, nothing is waited
    // for). Shares stats_busy with the stats reduction. Under the engine lock, after eyeStats.
    void eyeGs(Engine& e, const std::array<vpps4::ImageDesc, 2>& eyeDesc) {
        if (!Common::Diagnostics() || !snap_valid || frames % 120 != 0 || gs_logs >= 4) return;
        const vpps4::Renderer::DrawProbe* p = eyeProbe(eyeDesc);
        if (!p || !p->geom) {
            if (gs_none++ < 4) LOG_INFO(Render_Vulkan, "EYE_GS none: no geometry-shader draw wrote the eye target in the last picture");
            return;
        }
        if (!p->gsIndex || !p->gsVs) {
            LOG_INFO(Render_Vulkan, "EYE_GS unavailable: the GS rings of the eye draw are in an oversized scratch slab");
            return;
        }
        if (stats_busy.exchange(true)) return;
        const u32* index = p->gsIndex;
        const u32* ring = p->gsVs;
        const u64 count = p->gsIndexCount, ringDwords = p->gsVsDwords;
        const u32 maxVert = p->maxVertOut;
        e.device->drain();
        bool queued = false;
        e.device->withBackend([&] { queued = e.backend->encodeInterop(
            [](void*) {},
            "vp.eyegs",
            [this, index, ring, count, ringDwords, maxVert] {
                logEyeGs(index, count, ring, ringDwords, maxVert);
                stats_busy = false;
            }); });
        if (queued) ++gs_logs;
        else stats_busy = false;
    }

    int compose(Engine& e, u32 width, u32 height, std::span<const Region> regions) {
        u32 target_index = 0;
        void* target_texture = nullptr;
        HashJob job;  // the eye probe's reduction of this picture, if any: it rides this command buffer
        if (hash_job.slot >= 0) {
            job = std::move(hash_job);
            hash_job = {};
        }
        const bool probing = job.slot >= 0;
        if (!VpkengineXr::Begin(width, height, target_index, target_texture)) {
            dropHashJob(job);
            return -1;
        }
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
        const auto encode = [&](void* cbp) {
                id<MTLCommandBuffer> cb = (__bridge id<MTLCommandBuffer>)cbp;
                if (probing) encodeHashJob(cb, job);  // (a fresh command buffer: no encoder is open in it)
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
            };
        // (encodeInterop returns false only before it runs `encode` or registers the handler, so a refused job is given back here
        // and by no handler)
        if (probing)
            e.device->withBackend([&] { queued = e.backend->encodeInterop(
                encode, "vp.headset",
                [this, slot, job] {
                    finishHashJob(job);
                    std::scoped_lock l{done_mutex};
                    done[slot] = true;
                    done_cv.notify_all();
                }); });
        else
            e.device->withBackend([&] { queued = e.backend->encodeInterop(
                encode, "vp.headset",
                [this, slot] {
                    std::scoped_lock l{done_mutex};
                    done[slot] = true;
                    done_cv.notify_all();
                }); });
        if (!queued) {
            dropHashJob(job);
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
    std::array<vpps4::ImageDesc, 2> eyeDesc{};
    for (u32 k = 0; k < 2; ++k) {
        std::array<u32, 8> words{};
        std::memcpy(words.data(), &eye_textures[k], std::min(sizeof words, sizeof(AmdGpu::Image)));
        const vpps4::ImageDesc d = vpps4::decodeImage(words);
        eyeDesc[k] = d;
        // A T# at slice k > 0 of an array colour target (stereo eyes as the two slices of one
        // target): that slice as a 2D view. Slice 0 is the target's own address (textureOf).
        u16 slice = 0;
        const vpgpu::TextureId arrayTarget = e.renderer->colorTargetAt(d.address)
                                                 ? vpgpu::TextureId{}
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
        // P6: the same overlaps (target id and the pass that last drew it) and the texture the T# resolves to; first 40
        // pictures, then one in 600.
        if (impl->frames < 40 || impl->frames % 600 == 0) {
            uint16_t backLayer = 0;
            std::string backKind;
            const vpgpu::TextureId back = e.renderer->backingAt(d, backLayer, backKind);
            LOG_INFO(Render_Vulkan, "VPKENGINE_PROBE P6 eye {} {:#x} {}x{} backing={} tex={}/{} layer={} overlaps:{}", k, d.address,
                     d.width, d.height, backKind, back.index, back.generation, backLayer,
                     e.renderer->describeAt(d.address, u64(std::max(d.pitch, d.width)) * d.height * 4));
        }
    }
    // The eyes' drawing is submitted first: the composition runs after it on the same queue.
    e.present();
    if (!eyes[0] || !eyes[1]) {
        static std::atomic<u32> told{0};
        if (told++ < 4)
            LOG_WARNING(Render_Vulkan, "VPKENGINE_PRESENT eye pictures missing (left {}, right {}): black frame",
                        eyes[0] != nil, eyes[1] != nil);
    }
    impl->eyeStats(e, eyes, eyeDesc);
    if (pm::enabled()) impl->eyeProbe(e, eyes, eyeDesc);
    impl->eyeGs(e, eyeDesc);
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
