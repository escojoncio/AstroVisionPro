// SPDX-FileCopyrightText: Copyright 2026 shadPS4 Emulator Project
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include <atomic>
#include <exception>
#include <functional>

#include "common/logging/log.h"
#include "video_core/rasterizer_interface.h"

namespace VideoCore {

/// ASTRO_RENDERER=shadow: the command processor, the memory manager and the host page protections talk to
/// this rasterizer. The primary (Vulkan on KosmicKrisp) is the renderer that draws, writes guest memory,
/// writes labels and presents. The shadow (VPKEngine on the null backend) is given the same command stream
/// so that it builds its own state from it, and nothing it does is ever seen: it has no GPU, writes no guest
/// memory, no label, presents nothing.
///
/// The rule for each method of the interface:
///  - Work the shadow follows (draws, dispatches, DMA, memory events, syncs): the primary first, then the
///    shadow. Whatever the primary returns is what the caller gets.
///  - Everything that returns a value the caller acts on, or that has an effect visible outside the
///    renderer (a label, a WRITE_DATA, an occlusion result, GDS, a page fault answer): the primary alone.
///    The shadow could only disagree with it or write memory behind it.
/// The shadow runs behind the primary on the same thread, so the primary never waits for it except for the
/// CPU time it takes. If a call into the shadow throws or the shadow reports that it failed, the shadow is
/// switched off for good (`ASTRO_SHADOW disabled reason=...`) and the primary goes on alone.
/// Calls from different command processor threads (graphics and compute queues) are not serialised here:
/// each reaches the primary and the shadow in its own order, as it would reach one renderer.
class TeeRasterizer final : public RasterizerInterface {
public:
    /// `shadow_failed` (optional) is asked after each call into the shadow: true switches it off.
    TeeRasterizer(RasterizerInterface& primary_, RasterizerInterface& shadow_,
                  std::function<bool()> shadow_failed_ = {})
        : primary{primary_}, shadow{shadow_}, shadow_failed{std::move(shadow_failed_)} {}

    bool ShadowActive() const {
        return shadow_on.load(std::memory_order_acquire);
    }

    // ---- Work the shadow follows: primary, then shadow ----

    void Draw(bool is_indexed, u32 index_offset = 0) override {
        primary.Draw(is_indexed, index_offset);
        Shadow("Draw", [&](auto& s) { s.Draw(is_indexed, index_offset); });
    }
    void DrawIndirect(bool is_indexed, VAddr arg_address, u32 offset, u32 size, u32 max_count,
                      VAddr count_address) override {
        primary.DrawIndirect(is_indexed, arg_address, offset, size, max_count, count_address);
        Shadow("DrawIndirect", [&](auto& s) {
            s.DrawIndirect(is_indexed, arg_address, offset, size, max_count, count_address);
        });
    }
    void DispatchDirect() override {
        primary.DispatchDirect();
        Shadow("DispatchDirect", [&](auto& s) { s.DispatchDirect(); });
    }
    void DispatchIndirect(VAddr address, u32 offset, u32 size) override {
        primary.DispatchIndirect(address, offset, size);
        Shadow("DispatchIndirect", [&](auto& s) { s.DispatchIndirect(address, offset, size); });
    }
    // DMA: the shadow records it on its own (discarded) GPU timeline, so its tracker knows the range
    // changed; it never writes the bytes itself.
    void FillBuffer(VAddr address, u32 num_bytes, u32 value, bool is_gds) override {
        primary.FillBuffer(address, num_bytes, value, is_gds);
        Shadow("FillBuffer", [&](auto& s) { s.FillBuffer(address, num_bytes, value, is_gds); });
    }
    void CopyBuffer(VAddr dst, VAddr src, u32 num_bytes, bool dst_gds, bool src_gds) override {
        primary.CopyBuffer(dst, src, num_bytes, dst_gds, src_gds);
        Shadow("CopyBuffer",
               [&](auto& s) { s.CopyBuffer(dst, src, num_bytes, dst_gds, src_gds); });
    }
    // Written by the memory manager (outside a fault): the shadow drops what it made from the range. The
    // answer is the primary's. Host page faults do not reach this class: the page manager talks to the
    // primary, the only one that protects pages.
    bool InvalidateMemory(VAddr addr, u64 size) override {
        const bool result = primary.InvalidateMemory(addr, size);
        Shadow("InvalidateMemory", [&](auto& s) { s.InvalidateMemory(addr, size); });
        return result;
    }
    // Called with the memory manager's lock held: the shadow's side takes no lock of the renderer.
    void MapMemory(VAddr addr, u64 size) override {
        primary.MapMemory(addr, size);
        Shadow("MapMemory", [&](auto& s) { s.MapMemory(addr, size); });
    }
    void UnmapMemory(VAddr addr, u64 size) override {
        primary.UnmapMemory(addr, size);
        Shadow("UnmapMemory", [&](auto& s) { s.UnmapMemory(addr, size); });
    }
    // Cache flush / invalidate point: the shadow looks again at what it cannot watch there.
    void OnCoherencePoint(VAddr base, u64 size, u32 coher_cntl) override {
        primary.OnCoherencePoint(base, size, coher_cntl);
        Shadow("OnCoherencePoint", [&](auto& s) { s.OnCoherencePoint(base, size, coher_cntl); });
    }
    // Ends of a batch: the shadow submits what it recorded (to its null backend) and finishes it.
    u64 Flush() override {
        const u64 result = primary.Flush();
        Shadow("Flush", [&](auto& s) { s.Flush(); });
        return result;
    }
    void Finish() override {
        primary.Finish();
        Shadow("Finish", [&](auto& s) { s.Finish(); });
    }
    void OnSubmit() override {
        primary.OnSubmit();
        Shadow("OnSubmit", [&](auto& s) { s.OnSubmit(); });
    }

    // ---- The primary alone ----

    // Debug markers: the shadow has nothing to show them in.
    void ScopeMarkerBegin(const std::string_view& str, bool from_guest = false) override {
        primary.ScopeMarkerBegin(str, from_guest);
    }
    void ScopeMarkerEnd(bool from_guest = false) override {
        primary.ScopeMarkerEnd(from_guest);
    }
    void ScopedMarkerInsert(const std::string_view& str, bool from_guest = false) override {
        primary.ScopedMarkerInsert(str, from_guest);
    }
    void ScopedMarkerInsertColor(const std::string_view& str, const u32 color,
                                 bool from_guest = false) override {
        primary.ScopedMarkerInsertColor(str, color, from_guest);
    }
    // Returns GDS the primary's shaders wrote; the shadow's GDS is its own and nobody reads it.
    u32 ReadDataFromGds(u32 gds_offset) override {
        return primary.ReadDataFromGds(gds_offset);
    }
    void SyncGds() override {
        primary.SyncGds();
    }
    // Page faults and the page manager's questions: only the primary protects host pages, and the
    // answer decides whether the faulting access is retried.
    bool ReadMemory(VAddr addr, u64 size) override {
        return primary.ReadMemory(addr, size);
    }
    bool InvalidateHostPage(VAddr page, u64 size, bool write) override {
        return primary.InvalidateHostPage(page, size, write);
    }
    bool IsMapped(VAddr addr, u64 size) override {
        return primary.IsMapped(addr, size);
    }
    // Write occlusion results, labels (and their interrupts) and WRITE_DATA into guest memory, and decide
    // what the command processor waits for: the shadow must not do any of it, nor count in its place.
    bool ZPassDone(VAddr address, u32 pairs) override {
        return primary.ZPassDone(address, pairs);
    }
    bool SyncGpuWrites(VAddr addr, u64 size, bool wait) override {
        return primary.SyncGpuWrites(addr, size, wait);
    }
    void ScheduleLabelWrite(void* address, u64 value, u32 size,
                            std::function<void()> then) override {
        primary.ScheduleLabelWrite(address, value, size, std::move(then));
    }
    bool PrepareLabelWait(const void* address, u32 size, u32 function, u32 ref, u32 mask) override {
        return primary.PrepareLabelWait(address, size, function, ref, mask);
    }
    bool IdleLabelWait(const void* address, u32 size) override {
        return primary.IdleLabelWait(address, size);
    }
    void WriteDataOrdered(void* address, const void* data, u32 size) override {
        primary.WriteDataOrdered(address, data, size);
    }
    // CP sync is a barrier inside the primary's own queue.
    void CpSync() override {
        primary.CpSync();
    }

private:
    template <typename Fn>
    void Shadow(const char* what, Fn&& fn) {
        if (!shadow_on.load(std::memory_order_acquire)) {
            return;
        }
        try {
            fn(shadow);
        } catch (const std::exception& e) {
            Disable(what, e.what());
            return;
        } catch (...) {
            Disable(what, "unknown exception");
            return;
        }
        if (shadow_failed && shadow_failed()) {
            Disable(what, "the shadow renderer failed");
        }
    }

    void Disable(const char* what, const char* reason) {
        // (once: another thread may have switched it off at the same time)
        if (shadow_on.exchange(false, std::memory_order_acq_rel)) {
            LOG_ERROR(Render_Vulkan, "ASTRO_SHADOW disabled reason={} in {}", reason, what);
        }
    }

    RasterizerInterface& primary;
    RasterizerInterface& shadow;
    std::function<bool()> shadow_failed;
    std::atomic<bool> shadow_on{true};
};

} // namespace VideoCore
